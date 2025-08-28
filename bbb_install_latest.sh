#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -s -p "Enter a password for the Greenlight PostgreSQL user: " DB_PASSWORD
echo ""

# ======== VARIABLES ========
GREENLIGHT_DIR="/var/www/greenlight"
RBENV_ROOT="/var/www/greenlight/.rbenv"
RUBY_VERSION="3.1.6"

# ======== SYSTEM SETUP ========
echo "[1] Updating system packages..."
apt update -y && apt upgrade -y
apt install -y curl wget gnupg2 git build-essential libssl-dev libreadline-dev zlib1g-dev \
               postgresql postgresql-contrib redis-server \
               yarnpkg pkg-config libpq-dev libxml2-dev libxslt1-dev file imagemagick

# ======== NODEJS + YARN ========
echo "[2] Installing Node.js + Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt install -y nodejs
corepack enable
npm install -g yarn
echo "Node.js version: $(node -v)"
echo "NPM version: $(npm -v)"
echo "Yarn version: $(yarn -v)"

# ======== RUBY (via rbenv) ========
echo "[3] Checking Ruby installation..."
if command -v ruby >/dev/null 2>&1 && ruby -v | grep -q "ruby 3.1."; then
    echo "Ruby $(ruby -v) already installed. Skipping Ruby build."
else
    echo "Installing Ruby $RUBY_VERSION via rbenv..."
    mkdir -p "$GREENLIGHT_DIR"
    chown -R $USER:$USER "$GREENLIGHT_DIR"

    if [ ! -d "$RBENV_ROOT" ]; then
        git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
        mkdir -p "$RBENV_ROOT/plugins"
        git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
    fi

    export RBENV_ROOT="$RBENV_ROOT"
    export PATH="$RBENV_ROOT/bin:$PATH"
    eval "$(rbenv init -)"

    rbenv install -s $RUBY_VERSION
    rbenv global $RUBY_VERSION   # ✅ fixes the NOTE issue
    rbenv rehash
fi

gem install bundler

# ======== POSTGRESQL ========
echo "[4] Configuring PostgreSQL..."
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight;"
sudo -u postgres psql -c "DROP ROLE IF EXISTS greenlight;"
sudo -u postgres psql -c "CREATE ROLE greenlight LOGIN PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE greenlight OWNER greenlight;"

# ======== GREENLIGHT INSTALL ========
echo "[5] Installing Greenlight..."
rm -rf "$GREENLIGHT_DIR"
git clone -b v3 https://github.com/bigbluebutton/greenlight.git "$GREENLIGHT_DIR"
cd "$GREENLIGHT_DIR"

if [ ! -f config/database.yml.example ]; then
    echo "ERROR: config/database.yml.example not found in repo."
    exit 1
fi

cp config/database.yml.example config/database.yml
sed -i "s/username:.*/username: greenlight/" config/database.yml
sed -i "s/password:.*/password: $DB_PASSWORD/" config/database.yml

bundle install
yarn install

# ======== GREENLIGHT CONFIG ========
echo "[6] Setting up Greenlight..."
cp .env.example .env
sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(bundle exec rake secret)|" .env
sed -i "s|BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=http://$DOMAIN/bigbluebutton/api|" .env
sed -i "s|BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$(bbb-conf --secret | awk '/Secret/ {print $2}')|" .env

RAILS_ENV=production bundle exec rake db:setup
RAILS_ENV=production bundle exec rake assets:precompile

# ======== SERVICE SETUP ========
echo "[7] Creating Greenlight systemd service..."
cat >/etc/systemd/system/greenlight.service <<EOF
[Unit]
Description=Greenlight
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=$GREENLIGHT_DIR
ExecStart=/bin/bash -lc 'RAILS_ENV=production bundle exec puma -C config/puma.rb'
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable greenlight
systemctl start greenlight

echo "===== Installation Completed ====="
echo "Greenlight is running at: http://$DOMAIN"
