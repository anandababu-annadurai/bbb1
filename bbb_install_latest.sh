#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Clean Reinstall Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter email for Let's Encrypt SSL [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [default: greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

GREENLIGHT_USER=ubuntu
GREENLIGHT_DIR="/var/www/greenlight"

# ======== FIREWALL ========
echo "[0] Configuring firewall..."
sudo ufw --force reset
sudo ufw allow ssh
sudo ufw allow 22/tcp

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip

# ======== CLEAN EXISTING INSTALLATIONS ========
echo "[2] Removing old installations..."
sudo rm -rf /usr/local/rbenv
sudo rm -rf $GREENLIGHT_DIR
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_production;" || true
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_development;" || true
sudo -u postgres psql -c "DROP ROLE IF EXISTS greenlight;" || true

# ======== REMOVE OLD RUBY PPA ========
if [ -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list ]; then
    sudo rm /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list
    sudo apt update
fi

# ======== SET HOSTNAME ========
echo "[3] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL NODE & YARN ========
echo "[4] Installing Node.js 20.x and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
npm -v
yarn -v || npm install -g yarn

# ======== INSTALL SYSTEM-WIDE RBENV ========
echo "[5] Installing system-wide rbenv..."
sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
sudo mkdir -p /usr/local/rbenv/plugins
sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER /usr/local/rbenv
export RBENV_ROOT=/usr/local/rbenv
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

# ======== INSTALL RUBY 3.1.6 ========
echo "[6] Installing Ruby 3.1.6..."
sudo -u $GREENLIGHT_USER rbenv install 3.1.6
sudo -u $GREENLIGHT_USER rbenv global 3.1.6
sudo -u $GREENLIGHT_USER gem install bundler
sudo -u $GREENLIGHT_USER rbenv rehash

# ======== CONFIGURE POSTGRESQL ========
echo "[7] Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE ROLE greenlight LOGIN PASSWORD '$GREENLIGHT_DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight;"
sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight;"

# ======== INSTALL GREENLIGHT ========
echo "[8] Installing Greenlight..."
sudo mkdir -p $GREENLIGHT_DIR
sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR

sudo -i -u $GREENLIGHT_USER bash << EOF
export RBENV_ROOT=/usr/local/rbenv
export PATH="\$RBENV_ROOT/bin:\$PATH"
eval "\$(rbenv init -)"

cd $GREENLIGHT_DIR || git clone https://github.com/bigbluebutton/greenlight.git $GREENLIGHT_DIR && cd $GREENLIGHT_DIR

git checkout v3
git pull origin v3

bundle install --deployment --without development test
yarn install --check-files

bundle exec rake db:setup
bundle exec rake assets:precompile
EOF

echo "===== BBB + Greenlight Clean Reinstall Completed Successfully ====="
