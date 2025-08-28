#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Full Installation Started ====="

# ======== USER INPUT WITH DEFAULTS ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email address (for Let's Encrypt SSL) [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

GREENLIGHT_DIR="/var/www/greenlight"

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall (allow SSH)..."
sudo ufw --force reset
sudo ufw allow ssh
sudo ufw allow 22/tcp
sudo ufw --force enable

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip

# ======== HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname "$DOMAIN"
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s "$DOMAIN" -e "$EMAIL" -g

# ======== INSTALL NODE & YARN ========
echo "[4] Installing Node.js 20.x and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
npm -v
yarn -v || sudo npm install -g yarn

# ======== INSTALL SYSTEM-WIDE RBENV & RUBY ========
RUBY_VERSION="3.1.6"
RBENV_ROOT="/usr/local/rbenv"

if [ ! -d "$RBENV_ROOT" ]; then
    echo "[5] Installing system-wide rbenv..."
    sudo git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
    sudo mkdir -p "$RBENV_ROOT/plugins"
    sudo git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
    sudo chown -R $(whoami):$(whoami) "$RBENV_ROOT"
fi
export RBENV_ROOT="$RBENV_ROOT"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

# Install Ruby only if missing
if ! rbenv versions | grep -q "$RUBY_VERSION"; then
    echo "[6] Installing Ruby $RUBY_VERSION..."
    rbenv install -s "$RUBY_VERSION"
fi
rbenv global "$RUBY_VERSION"
gem install bundler

# ======== CONFIGURE POSTGRESQL ========
echo "[7] Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE ROLE greenlight_user WITH PASSWORD '$GREENLIGHT_DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight_user;" || true

# ======== INSTALL OR UPDATE GREENLIGHT ========
echo "[8] Installing/Updating Greenlight..."
mkdir -p /var/www
cd /var/www

if [ -d "$GREENLIGHT_DIR/.git" ]; then
    cd "$GREENLIGHT_DIR"
    git fetch --all
    git checkout v3
    git reset --hard origin/v3
else
    rm -rf "$GREENLIGHT_DIR"
    git clone https://github.com/bigbluebutton/greenlight.git "$GREENLIGHT_DIR"
    cd "$GREENLIGHT_DIR"
    git checkout v3
fi

# Set correct Ruby version
echo "$RUBY_VERSION" > .ruby-version
rbenv local "$RUBY_VERSION"
eval "$(rbenv init -)"

# Setup database.yml
if [ ! -f "config/database.yml" ] && [ -f "config/database.yml.example" ]; then
    cp config/database.yml.example config/database.yml
    sed -i "s/username:.*/username: greenlight_user/" config/database.yml
    sed -i "s/password:.*/password: $GREENLIGHT_DB_PASS/" config/database.yml
fi

bundle install
yarn install || echo "[WARN] Yarn warnings ignored"

# ======== PRECOMPILE ASSETS & SETUP DB ========
echo "[9] Precompiling assets and configuring DB..."
export RAILS_ENV=production
bundle exec rake assets:precompile
bundle exec rake db:create db:migrate db:seed

# ======== PUMA SYSTEMD SERVICE ========
echo "[10] Creating systemd service for Puma..."
cat > /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight Puma Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/www/greenlight
Environment=RAILS_ENV=production
ExecStart=$RBENV_ROOT/shims/bundle exec puma -C config/puma.rb
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable greenlight
systemctl restart greenlight

# ======== NGINX + SSL ========
echo "[11] Configuring Nginx for $DOMAIN..."
cat > /etc/nginx/sites-available/greenlight <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/greenlight/public;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/greenlight
nginx -t && systemctl restart nginx

echo "[12] Requesting SSL certificate..."
certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

echo "✅ BigBlueButton + Greenlight installed and secured with HTTPS at https://$DOMAIN"
