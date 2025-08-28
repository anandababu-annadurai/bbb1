#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_greenlight_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

GREENLIGHT_DIR="/var/www/greenlight"
RBENV_DIR="$GREENLIGHT_DIR/.rbenv"
RUBY_VERSION="3.1.6"
DB_PASS="greenlightpass"

# ======== MANUAL ROLLBACK FUNCTION ========
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
        sudo -u postgres HOME=/tmp psql greenlight_db < "$BACKUP_PATH/greenlight_db.sql"
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

# ======== USER INPUT ========
read -p "Enter your domain URL (e.g., bbb.example.com): " DOMAIN
DOMAIN=${DOMAIN:-$(curl -s ifconfig.me)}
echo "[INFO] Using domain: $DOMAIN"

read -p "Enter your email for SSL (default: admin@$DOMAIN): " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

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

# ======== SYSTEM UPDATE & DEPENDENCIES ========
echo "[1] Installing dependencies..."
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get install -y build-essential libssl-dev libreadline-dev zlib1g-dev git curl gnupg2 \
                        nginx certbot python3-certbot-nginx postgresql postgresql-contrib

# ======== NODE.JS + YARN ========
echo "[2] Installing Node.js & Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g yarn
echo "✔ Node.js: $(node -v), NPM: $(npm -v), Yarn: $(yarn -v)"

# ======== RUBY VIA RBENV ========
echo "[3] Installing Ruby via rbenv..."
export RBENV_ROOT="$RBENV_DIR"
export PATH="$RBENV_ROOT/bin:$PATH"

if [ ! -d "$RBENV_DIR" ]; then
    mkdir -p "$GREENLIGHT_DIR"
    git clone https://github.com/rbenv/rbenv.git "$RBENV_DIR"
    git clone https://github.com/rbenv/ruby-build.git "$RBENV_DIR/plugins/ruby-build"
fi

eval "$(rbenv init -)"

if rbenv versions | grep -q "$RUBY_VERSION"; then
    echo "✔ Ruby $RUBY_VERSION already installed"
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
echo "[4] Configuring PostgreSQL..."
sudo -u postgres HOME=/tmp psql <<EOF
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
    echo "[5] Backing up Greenlight database and .env before upgrade..."
    BACKUP_DIR="$GREENLIGHT_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres HOME=/tmp pg_dump greenlight_db > "$BACKUP_DIR/greenlight_db.sql"
    if [ -f "$GREENLIGHT_DIR/.env" ]; then
        cp "$GREENLIGHT_DIR/.env" "$BACKUP_DIR/.env"
    fi
    echo "✔ Backup completed: $BACKUP_DIR"
fi

# ======== GREENLIGHT INSTALL / UPGRADE ========
echo "[6] Installing or upgrading Greenlight..."
trap 'echo "[ERROR] Something went wrong. Starting rollback..."; manual_rollback' ERR

cd /var/www

if [ -d "greenlight" ]; then
    cd greenlight
    if [ ! -d ".git" ]; then
        echo "[INFO] Existing folder is not a git repo. Re-cloning..."
        cd ..
        rm -rf greenlight
        git clone -b v3 https://github.com/bigbluebutton/greenlight.git
        cd greenlight
    else
        echo "[INFO] Updating existing Greenlight repo..."
        git fetch origin
        git checkout v3
        git reset --hard origin/v3
    fi
else
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
echo "[7] Configuring NGINX..."
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
echo "[8] Setting up SSL..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL || true
sed -i "s|http://$DOMAIN|https://$DOMAIN|" .env
echo "✔ SSL and .env updated to HTTPS"

# ======== SYSTEMD SERVICE ========
echo "[9] Creating systemd service..."
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

echo "===== BBB + Greenlight Installation/Upgrade Completed Successfully ====="
echo "Visit: https://$DOMAIN"
sudo certbot certificates | grep "Expiry"
