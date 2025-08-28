#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email address (for Let's Encrypt SSL) [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

# ======== VARIABLES ========
GREENLIGHT_DIR="/var/www/greenlight"
RBENV_ROOT="/usr/local/rbenv"
SSH_PORT=22

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall with SSH protection..."
sudo ufw --force reset
sudo ufw allow $SSH_PORT
sudo ufw allow 22/tcp
sudo ufw enable

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip

# ======== INSTALL NODE.JS, NPM & YARN ========
echo "[2] Installing Node.js, npm, Yarn..."
sudo apt remove -y nodejs npm || true
sudo apt purge -y nodejs npm || true
sudo apt autoremove -y || true
sudo rm -rf /usr/local/lib/node_modules
sudo rm -f /usr/local/bin/node
sudo rm -f /usr/local/bin/npm

curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
echo "✔ Node.js: $(node -v), npm: $(npm -v)"
if ! command -v yarn >/dev/null 2>&1; then
    npm install -g yarn
fi
echo "✔ Yarn: $(yarn -v)"

# ======== SYSTEM-WIDE RBENV ========
if [ ! -d "$RBENV_ROOT" ]; then
    echo "[3] Installing system-wide rbenv and Ruby..."
    sudo git clone https://github.com/rbenv/rbenv.git $RBENV_ROOT
    sudo mkdir -p $RBENV_ROOT/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git $RBENV_ROOT/plugins/ruby-build
    sudo chown -R $USER:$USER $RBENV_ROOT
fi

export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

RUBY_VERSION="3.1.6"
if ! rbenv versions | grep -q "$RUBY_VERSION"; then
    rbenv install $RUBY_VERSION
fi
rbenv global $RUBY_VERSION
gem install bundler --no-document

# ======== POSTGRESQL SETUP ========
echo "[4] Configuring PostgreSQL..."
sudo -u postgres psql -c "DO \$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'greenlight_user') THEN
      CREATE ROLE greenlight_user LOGIN PASSWORD '$GREENLIGHT_DB_PASS';
   END IF;
END
\$;"
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight_user;" || echo "DB already exists"
sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight_user;" || echo "DB already exists"
echo "✔ PostgreSQL configured"

# ======== GREENLIGHT INSTALL / UPGRADE ========
echo "[5] Installing/upgrading Greenlight..."
sudo mkdir -p $GREENLIGHT_DIR
sudo chown -R $USER:$USER $GREENLIGHT_DIR

cd $GREENLIGHT_DIR
if [ ! -d ".git" ]; then
    git clone -b v3 https://github.com/bigbluebutton/greenlight.git .
else
    git fetch origin
    git reset --hard origin/v3
fi

# Ensure proper Ruby version
echo $RUBY_VERSION > .ruby-version
bundle config set --local path 'vendor/bundle'
bundle install --without development test

# Copy config files if missing
[ ! -f config/database.yml ] && cp config/database.yml.example config/database.yml
[ ! -f .env ] && cp .env.example .env

# Precompile assets and setup DB
bundle exec rake db:setup
bundle exec rake assets:precompile
echo "✔ Greenlight installed/upgraded successfully"
