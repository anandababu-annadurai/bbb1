#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_greenlight_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ======== DEFAULT VARIABLES ========
GREENLIGHT_DIR="/var/www/greenlight"
RBENV_DIR="/usr/local/rbenv"
RUBY_VERSION="3.1.6"
DB_NAME="greenlight_db"
DB_USER="greenlight_user"
DB_PASS="greenlightpass"

# ======== FUNCTIONS ========
manual_rollback() {
    echo "Available backups:"
    ls -1 "$GREENLIGHT_DIR/backups/"
    read -p "Enter backup folder to restore: " BACKUP_CHOICE
    BACKUP_PATH="$GREENLIGHT_DIR/backups/$BACKUP_CHOICE"

    if [ ! -d "$BACKUP_PATH" ]; then
        echo "Backup folder not found: $BACKUP_PATH"
        exit 1
    fi

    echo "[ROLLBACK] Restoring backup: $BACKUP_PATH"
    if [ -f "$BACKUP_PATH/${DB_NAME}.sql" ]; then
        sudo -u postgres HOME=/tmp psql "$DB_NAME" < "$BACKUP_PATH/${DB_NAME}.sql"
        echo "[ROLLBACK] Database restored."
    fi

    [ -f "$BACKUP_PATH/.env" ] && cp "$BACKUP_PATH/.env" "$GREENLIGHT_DIR/.env" && echo "[ROLLBACK] .env restored."
    echo "[ROLLBACK] Completed successfully."
    exit 0
}

if [[ "$1" == "--rollback" ]]; then
    manual_rollback
fi

echo "===== BBB + Greenlight Full Installer Started ====="

# ======== USER INPUT ========
read -p "Enter your domain (e.g., bbb.example.com): " DOMAIN
DOMAIN=${DOMAIN:-$(curl -s ifconfig.me)}
echo "[INFO] Using domain: $DOMAIN"

read -p "Enter your email for SSL (default: admin@$DOMAIN): " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user (default: greenlightpass): " DB_PASS_INPUT
DB_PASS=${DB_PASS_INPUT:-$DB_PASS}
echo

# ======== FIREWALL ========
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
                        nginx certbot python3-certbot-nginx postgresql postgresql-contrib ufw wget lsb-release software-properties-common

# ======== BIGBLUEBUTTON INSTALL ========
echo "[2] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g
echo "✔ BBB installation complete"

# ======== NODE & YARN ========
echo "[3] Installing Node.js 20.x and Yarn..."
sudo apt remove -y nodejs npm || true
sudo apt autoremove -y
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
echo "✔ Node.js: $(node -v), NPM: $(npm -v)"
sudo npm install -g yarn
echo "✔ Yarn version: $(yarn -v)"

# ======== RUBY VIA SYSTEM-WIDE RBENV ========
echo "[4] Installing Ruby via system-wide rbenv..."
export RBENV_ROOT="$RBENV_DIR"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"

if [ ! -d "$RBENV_DIR" ]; then
    sudo git clone https://github.com/rbenv/rbenv.git $RBENV_DIR
    sudo mkdir -p $RBENV_DIR/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git $RBENV_DIR/plugins/ruby-build
    sudo chown -R $USER:$USER $RBENV_DIR
fi

eval "$(rbenv init -)"

if ! rbenv versions | grep -q "$RUBY_VERSION"; then
    echo "[INFO] Installing Ruby $RUBY_VERSION..."
    rbenv install "$RUBY_VERSION"
else
    echo "[INFO] Ruby $RUBY_VERSION already installed, skipping."
fi
rbenv global "$RUBY_VERSION"

if ! gem list bundler -i > /dev/null 2>&1; then
    gem install bundler
fi
echo "✔ Ruby and Bundler ready"

# ======== POSTGRESQL SETUP ========
echo "[5] Configuring PostgreSQL..."
sudo -u postgres HOME=/tmp psql <<EOF
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') THEN
      CREATE ROLE $DB_USER LOGIN PASSWORD '$DB_PASS';
   END IF;
END
\$do\$;

DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME') THEN
      CREATE DATABASE $DB_NAME OWNER $DB_USER;
   END IF;
END
\$do\$;
EOF
echo "✔ PostgreSQL configured"

# ======== GREENLIGHT BACKUP ========
mkdir -p "$GREENLIGHT_DIR/backups"
if [ -d "$GREENLIGHT_DIR" ]; then
    echo "[6] Backing up Greenlight database and .env before upgrade..."
    BACKUP_DIR="$GREENLIGHT_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    sudo -u postgres HOME=/tmp pg_dump "$DB_NAME" > "$BACKUP_DIR/${DB_NAME}.sql"
    [ -f "$GREENLIGHT_DIR/.env" ] && cp "$GREENLIGHT_DIR/.env" "$BACKUP_DIR/.env"
    echo "✔ Backup completed: $BACKUP_DIR"
fi

# ======== GREENLIGHT INSTALL / UPGRADE ========
echo "[7] Installing or upgrading Greenlight..."
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

[ ! -f config/database.yml ] && cp config/database.yml.example config/database.yml
sed -i "s/username:.*/username: $DB_USER/" config/database.yml
sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sed -i "s/database:.*/database: $DB_NAME/" config/database.yml

echo "$RUBY_VERSION" > .ruby-version
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"
rbenv global "$RUBY_VERSION"

bundle install
yarn install
[ ! -f .env ] && cp .env.example .env
BBB_ENDPOINT="http://$DOMAIN/bigbluebutton/api"
BBB_SECRET=$(sudo bbb-conf --secret | awk '/Secret/ {print $2}')
sed -i "s|BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BBB_ENDPOINT|" .env
sed -i "s|BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$BBB_SECRET|" .env
sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(bundle exec rake secret)|" .env

RAILS_ENV=production bundle exec rake db:migrate
RAILS_ENV=production bundle exec rake assets:precompile
echo "✔ Greenlight installed/upgraded"

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

# ======== SSL ========
echo "[9] Setting up SSL..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL || true
sed -i "s|http://$DOMAIN|https://$DOMAIN|" .env
echo "✔ SSL configured"

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
sudo systemctl restart greenlight

echo "✅ BBB + Greenlight fully installed and running at https://$DOMAIN"
