#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT WITH DEFAULTS ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email address (for Let's Encrypt SSL) [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [default: greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

read -p "Enter SSH port [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

GREENLIGHT_DIR="/var/www/greenlight"

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall with SSH protection..."
sudo ufw --force reset
sudo ufw allow $SSH_PORT/tcp

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip

# ======== SET HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ======== INSTALL NODE & YARN ========
echo "[4] Installing Node.js 20.x and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs || true  # ignore broken package errors
sudo npm install -g npm@latest
npm -v
yarn -v || sudo npm install -g yarn

# ======== INSTALL SYSTEM-WIDE RBENV ========
RBENV_ROOT="/usr/local/rbenv"
if [ ! -d "$RBENV_ROOT" ]; then
    echo "[5] Installing system-wide rbenv..."
    sudo git clone https://github.com/rbenv/rbenv.git $RBENV_ROOT
    sudo mkdir -p $RBENV_ROOT/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git $RBENV_ROOT/plugins/ruby-build
    sudo chown -R $USER:$USER $RBENV_ROOT
fi

# Add rbenv to PATH
export RBENV_ROOT="$RBENV_ROOT"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

# ======== INSTALL RUBY 3.1.6 IF NOT PRESENT ========
if ! rbenv versions | grep -q "3.1.6"; then
    echo "[6] Installing Ruby 3.1.6..."
    rbenv install 3.1.6
fi
rbenv global 3.1.6
gem install bundler --no-document
rbenv rehash

# ======== CONFIGURE POSTGRESQL ========
echo "[7] Configuring PostgreSQL..."
sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='greenlight_user') THEN CREATE ROLE greenlight_user LOGIN PASSWORD '$GREENLIGHT_DB_PASS'; END IF; END \$\$;"
sudo -u postgres psql -c "CREATE DATABASE IF NOT EXISTS greenlight_production OWNER greenlight_user;"

# ======== INSTALL OR UPGRADE GREENLIGHT ========
echo "[8] Installing/upgrading Greenlight..."
mkdir -p $GREENLIGHT_DIR
cd $GREENLIGHT_DIR

if [ ! -d "$GREENLIGHT_DIR/.git" ]; then
    git clone -b v3 https://github.com/bigbluebutton/greenlight.git .
else
    git fetch origin
    git reset --hard origin/v3
fi

# Use correct Ruby version
rbenv local 3.1.6
bundle config set path 'vendor/bundle'
bundle install --without development test --jobs 4
yarn install

# ======== SETUP DATABASE & PRECOMPILE ASSETS ========
if [ ! -f ".env" ]; then
    cp .env.example .env || echo "Created default .env"
fi

bundle exec rake db:setup
bundle exec rake assets:precompile

echo "===== BBB + Greenlight Installation Completed Successfully ====="
