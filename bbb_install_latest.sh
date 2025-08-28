#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter PostgreSQL password: " DB_PASSWORD

# ======== VARIABLES ========
GREENLIGHT_DIR="/var/www/greenlight"
RBENV_ROOT="$GREENLIGHT_DIR/.rbenv"

# ======== UPDATE SYSTEM ========
echo "[1] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# ======== DEPENDENCIES ========
echo "[2] Installing dependencies..."
apt-get install -y git curl build-essential libssl-dev libreadline-dev zlib1g-dev libpq-dev postgresql postgresql-contrib nginx

# ======== BBB INSTALLATION ========
echo "[3] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | bash -s -- -v bionic-230 -s "$DOMAIN" -e admin@"$DOMAIN" -g

# ======== NODE.JS & NPM ========
echo "[4] Checking Node.js installation..."
NODE_VERSION=$(node -v 2>/dev/null || echo "none")
if [[ "$NODE_VERSION" == v20* ]]; then
    echo "Node.js $NODE_VERSION already installed. Skipping."
else
    echo "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
echo "Node.js version: $(node -v)"
echo "NPM version: $(npm -v)"

# ======== YARN ========
echo "[5] Checking Yarn installation..."
YARN_VERSION=$(yarn -v 2>/dev/null || echo "none")
if [[ "$YARN_VERSION" == 1.* ]]; then
    echo "Yarn $YARN_VERSION already installed. Skipping."
else
    echo "Installing Yarn..."
    npm install -g yarn
fi
echo "Yarn version: $(yarn -v)"

# ======== RUBY (via rbenv, per-user install) ========
echo "[6] Checking Ruby installation..."
RUBY_VERSION=3.1.6
if command -v ruby >/dev/null 2>&1 && ruby -v | grep -q "ruby 3.1."; then
    echo "Ruby $(ruby -v) already installed. Skipping."
else
    echo "Installing Ruby $RUBY_VERSION via rbenv..."
    mkdir -p "$GREENLIGHT_DIR"
    cd "$GREENLIGHT_DIR"

    if [ ! -d "$RBENV_ROOT" ]; then
        git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
        mkdir -p "$RBENV_ROOT/plugins"
        git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
    fi

    export RBENV_ROOT="$RBENV_ROOT"
    export PATH="$RBENV_ROOT/bin:$PATH"
    eval "$(rbenv init -)"

    rbenv install -s $RUBY_VERSION
    rbenv global $RUBY_VERSION
    rbenv rehash
fi

gem install bundler

# ======== POSTGRES CONFIG ========
echo "[7] Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE ROLE greenlight WITH LOGIN PASSWORD '$DB_PASSWORD';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight;" || true

# ======== GREENLIGHT INSTALL ========
echo "[8] Installing Greenlight..."
rm -rf "$GREENLIGHT_DIR"
git clone -b v3 https://github.com/bigbluebutton/greenlight.git "$GREENLIGHT_DIR"
cd "$GREENLIGHT_DIR"

cp config/database.yml.example config/database.yml
sed -i "s/username:.*/username: greenlight/" config/database.yml
sed -i "s/password:.*/password: $DB_PASSWORD/" config/database.yml

bundle install
yarn install

echo "===== Installation Completed Successfully ====="
