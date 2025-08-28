#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_greenlight_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ======== MANUAL ROLLBACK FUNCTION ========
GREENLIGHT_DIR="/var/www/greenlight"

manual_rollback() {
    echo "Available backups:"
    ls -1 "$GREENLIGHT_DIR/backups/"
    
    read -p "Enter the backup folder to restore: " BACKUP_CHOICE
    BACKUP_PATH="$GREENLIGHT_DIR/backups/$BACKUP_CHOICE"

    if [ ! -d "$BACKUP_PATH" ]; then
        echo "Backup folder not found: $BACKUP_PATH"
        exit 1
    fi

    echo "[MANUAL ROLLBACK] Restoring backup: $BACKUP_PATH"

    # Restore database
    if [ -f "$BACKUP_PATH/greenlight_db.sql" ]; then
        sudo -u postgres psql greenlight_db < "$BACKUP_PATH/greenlight_db.sql"
        echo "[MANUAL ROLLBACK] Database restored."
    fi

    # Restore .env
    if [ -f "$BACKUP_PATH/.env" ]; then
        cp "$BACKUP_PATH/.env" "$GREENLIGHT_DIR/.env"
        echo "[MANUAL ROLLBACK] .env restored."
    fi

    echo "[MANUAL ROLLBACK] Completed successfully."
    exit 0
}

# ======== CHECK FOR ROLLBACK OPTION ========
if [[ "$1" == "--rollback" ]]; then
    manual_rollback
fi

echo "===== BBB + Greenlight Installation/Upgrade Started ====="

# ======== VARIABLES ========
read -p "Enter your domain URL (e.g., bbb.example.com): " DOMAIN
DOMAIN=${DOMAIN:-$(curl -s ifconfig.me)}
echo "[INFO] Using domain: $DOMAIN"

DB_PASS="greenlightpass"
echo "[INFO] Greenlight DB password: $DB_PASS"

RBENV_DIR="$GREENLIGHT_DIR/.rbenv"
RUBY_VERSION="3.1.6"

# ======== AUTOMATIC ROLLBACK FUNCTION ========
rollback_greenlight() {
    echo "[ROLLBACK] Restoring latest Greenlight backup..."
    
    LATEST_BACKUP=$(ls -dt "$GREENLIGHT_DIR/backups/"* 2>/dev/null | head -1)
    if [ -z "$LATEST_BACKUP" ]; then
        echo "[ROLLBACK] No backup found! Cannot rollback."
        exit 1
    fi

    echo "[ROLLBACK] Using backup: $LATEST_BACKUP"

    # Restore database
    if [ -f "$LATEST_BACKUP/greenlight_db.sql" ]; then
        sudo -u postgres psql greenlight_db < "$LATEST_BACKUP/greenlight_db.sql"
        echo "[ROLLBACK] Database restored."
    fi

    # Restore .env
    if [ -f "$LATEST_BACKUP/.env" ]; then
        cp "$LATEST_BACKUP/.env" "$GREENLIGHT_DIR/.env"
        echo "[ROLLBACK] .env restored."
    fi

    echo "[ROLLBACK] Rollback completed successfully."
    exit 0
}

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 16384:32768/udp
sudo ufw --force enable
echo "✔ Firewall configured"

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt-get update -y && sudo apt-get upgrade -y

# ======== DEPENDENCIES ========
echo "[2] Installing dependencies..."
sudo apt-get install -y build-essential libssl-dev libreadline-dev zlib1g-dev git curl gnupg2 \
                        nginx certbot python3-certbot-nginx postgresql postgresql-contrib

# ======== NODE.JS + YARN ========
echo "[3] Installing Node.js & Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g yarn
echo "✔ Node.js: $(node -v), NPM: $(npm -v), Yarn: $(yarn -v)"

# ======== RUBY VIA RBENV (PER-USER, SKIP IF INSTALLED) ========
echo "[4] Installing Ruby via rbenv..."
export RBENV_ROOT="$RBENV_DIR"
export PATH="$RBENV_ROOT/bin:$PATH"

if [ ! -d "$RBENV_DIR" ]; then
    mkdir -p "$GREENLIGHT_DIR"
    git clone https://github.com/rbenv/rbenv.git "$RBENV_DIR"
    git clone https://github.com/rbenv/ruby-build.git "$RBENV_DIR/plugins/ruby-build"
fi

eval "$(rbenv init -)"

if rbenv versions | grep -q "$RUBY_VERSION"; then
    echo "✔ Ruby $RUBY_VERSION already installed under $RBENV_DIR"
else
    echo "[INFO] Installing Ruby $RUBY_VERSION..."
    rbenv install "$RUBY_VERSION"
    rbenv global "$RUBY_VERSION"
fi

if ! gem list bundler -i > /dev/null 2>&1; then
    gem install bundler
fi
echo "✔ Ruby and Bundler ready"

# ======== POSTGRESQL SETUP ========
echo "[5] Configuring PostgreSQL..."
sudo -u postgres psql <<EOF
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'greenlight_user') THEN
      CREATE ROLE greenlight_user LOGIN PASSWORD '$DB_PASS';
   END IF;
END
\$do\$;

CREATE DATABASE greenlight_db OWNER greenlight_user;
EOF
echo "✔ PostgreSQL configured"

# ======== BACKUP BEFORE UPGRADE ========
if [ -d "$GREENLIGHT_DIR" ]; then
    echo "[6] Backing up Greenlight database and .env before upgrade..."
    BACKUP_DIR="$GREENLIGHT_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres pg_dump greenlight_db > "$BACKUP_DIR/greenlight_db.sql"
    if [ -f "$GREENLIGHT_DIR/.env" ]; then
        cp "$GREENLIGHT_DIR/.env" "$BACKUP_DIR/.env"
    fi
    echo "✔ Backup completed: $BACKUP_DIR"
fi

# ======== GREENLIGHT INSTALL / UPGRADE ========
echo "[7] Installing or upgrading Greenlight..."
trap 'echo "[ERROR] Something went wrong. Starting rollback..."; rollback_greenlight' ERR

cd /var/www

if [ -d "greenlight" ]; then
    echo "[INFO] Greenlight directory exists, pulling latest v3 branch..."
    cd greenlight
    git fetch origin
    git checkout v3
    git reset --hard origin/v3
else
    echo "[INFO] Cloning Greenlight repository..."
    git clone -b v3 https://github.com/bigbluebutton/greenlight.git
    cd greenlight
fi

if [ ! -f config/database.yml ]; then
    cp config/database.yml.example config/database.yml
fi
sed -i "s/username:.*/username: greenlight_user/" config/database.yml
sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sed -i "s/database:.*/database: greenlight_db/" config/database.yml

bundle install
yarn install

if [ ! -f .env ]; then
    cp .env.example .env
fi
BBB_ENDPOINT="http://$DOMAIN/bigbluebutton/api"
BBB_SECRET=$(sudo bbb-conf --secret | awk '/Secret/ {print $2}')
sed -i "s|BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BBB_ENDPOINT|" .env
sed -i "s|BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$BBB_SECRET|" .env
sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(bundle exec rake secret)|" .env

RAILS_ENV=production bundle exec rake db:migrate
RAILS_ENV=production bundle exec rake assets:precompile
echo "✔ Greenlight installed or upgraded"

# ======== NGINX CONFIG ========
echo "[8] Configuring NGINX..."
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/greenlight/public;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# ======== SSL SETUP ========
echo "[9] Setting up SSL with Certbot..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || true

# ======== UPDATE GREENLIGHT .ENV TO HTTPS ========
sed -i "s|http://$DOMAIN|https://$DOMAIN|" .env
echo "✔ Greenlight .env updated to HTTPS"

# ======== SYSTEMD SERVICE ========
echo "[10] Creating systemd service..."
sudo tee /etc/systemd/system/greenlight.service > /dev/null <<EOF
[Unit]
Description=Greenlight Rails App
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/var/www/greenlight
Environment=RAILS_ENV=production
ExecStart=$RBENV_DIR/shims/bundle exec rails server -b 127.0.0.1 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl start greenlight

# ======== DONE ========
echo "===== BBB + Greenlight Installation/Upgrade Completed Successfully ====="
echo "Visit: https://$DOMAIN"
sudo certbot certificates | grep "Expiry"
