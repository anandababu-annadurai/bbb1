#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT WITH DEFAULTS ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter email for Let's Encrypt SSL [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -p "Enter SSH port for firewall (default 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

read -sp "Enter password for Greenlight DB user [greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

GREENLIGHT_DIR="/var/www/greenlight"
GREENLIGHT_USER="${SUDO_USER:-$USER}"

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall..."
sudo ufw --force reset
sudo ufw allow "$SSH_PORT"/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip yarn

# ======== NODE.JS & NPM ========
echo "[2] Installing Node.js & Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
node -v
npm -v
yarn -v

# ======== SYSTEM-WIDE RBENV & RUBY ========
echo "[3] Installing system-wide rbenv & Ruby..."
if [ ! -d "/usr/local/rbenv" ]; then
    sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    sudo mkdir -p /usr/local/rbenv/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
    sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER /usr/local/rbenv
fi

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

if ! rbenv versions | grep -q "3.1.6"; then
    echo "[INFO] Installing Ruby 3.1.6..."
    rbenv install 3.1.6
fi
rbenv global 3.1.6

# ======== BUNDLER ========
gem install bundler
bundler -v

# ======== POSTGRESQL CONFIGURATION ========
echo "[4] Configuring PostgreSQL..."
sudo -u postgres psql -c "DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'greenlight_user') THEN
      CREATE ROLE greenlight_user WITH LOGIN PASSWORD '$GREENLIGHT_DB_PASS';
   END IF;
END \$\$;"
sudo -u postgres psql -c "DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'greenlight_production') THEN
      CREATE DATABASE greenlight_production OWNER greenlight_user;
   END IF;
END \$\$;"

# ======== GREENLIGHT INSTALL/UPGRADE ========
echo "[5] Installing/upgrading Greenlight..."
sudo mkdir -p "$GREENLIGHT_DIR"
sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER "$GREENLIGHT_DIR"

# Git safe.directory
sudo -u $GREENLIGHT_USER git config --global --add safe.directory $GREENLIGHT_DIR
cd $GREENLIGHT_DIR

if [ -d "$GREENLIGHT_DIR/.git" ]; then
    echo "[INFO] Updating existing Greenlight repo..."
    sudo -u $GREENLIGHT_USER git fetch origin v3
    sudo -u $GREENLIGHT_USER git reset --hard origin/v3
else
    echo "[INFO] Cloning Greenlight v3 branch..."
    sudo -u $GREENLIGHT_USER git clone --branch v3 https://github.com/bigbluebutton/greenlight.git .
fi

# Ensure .env and database.yml exist
if [ ! -f ".env" ]; then
    sudo -u $GREENLIGHT_USER cp .env.example .env || sudo -u $GREENLIGHT_USER touch .env
fi
if [ ! -f "config/database.yml" ]; then
    sudo -u $GREENLIGHT_USER cp config/database.yml.example config/database.yml || true
fi

# Install gems and JS dependencies as non-root
sudo -u $GREENLIGHT_USER bundle install --deployment --without development test
sudo -u $GREENLIGHT_USER yarn install --check-files

# Precompile assets & migrate DB
sudo -u $GREENLIGHT_USER bundle exec rake db:migrate
sudo -u $GREENLIGHT_USER bundle exec rake assets:precompile

echo "===== BBB + Greenlight Installation Completed Successfully ====="
