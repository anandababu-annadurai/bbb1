#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Full Reinstall Started ====="

# ======== USER INPUT WITH DEFAULTS ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter email for Let's Encrypt SSL [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [default: greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

GREENLIGHT_USER=ubuntu
GREENLIGHT_DIR="/var/www/greenlight"

# ======== FIREWALL SETUP ========
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

# ======== SET HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL NODE & YARN ========
echo "[3] Installing Node.js 20.x and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
npm -v
yarn -v || sudo npm install -g yarn

# ======== REMOVE OLD GREENLIGHT & RBENV ========
echo "[4] Cleaning up old installations..."
sudo rm -rf $GREENLIGHT_DIR
sudo rm -rf /usr/local/rbenv

# ======== INSTALL SYSTEM-WIDE RBENV ========
echo "[5] Installing system-wide rbenv..."
sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
sudo mkdir -p /usr/local/rbenv/plugins
sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER /usr/local/rbenv

# ======== INSTALL RUBY 3.1.6 AS GREENLIGHT USER ========
echo "[6] Installing Ruby 3.1.6..."
sudo -i -u $GREENLIGHT_USER bash << EOF
export RBENV_ROOT=/usr/local/rbenv
export PATH="\$RBENV_ROOT/bin:\$PATH"
eval "\$(rbenv init -)"

if ! rbenv versions | grep -q "3.1.6"; then
    rbenv install 3.1.6
fi

rbenv global 3.1.6
gem install bundler
rbenv rehash
EOF

# ======== CONFIGURE POSTGRESQL ========
echo "[7] Configuring PostgreSQL..."
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='greenlight'" | grep -q 1 || \
sudo -u postgres psql -c "CREATE ROLE greenlight LOGIN PASSWORD '$GREENLIGHT_DB_PASS';"

for DB in greenlight_production greenlight_development; do
    sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE $DB OWNER greenlight;"
done

# ======== INSTALL GREENLIGHT ========
echo "[8] Installing Greenlight..."
sudo mkdir -p $GREENLIGHT_DIR
sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR

sudo -i -u $GREENLIGHT_USER bash << 'EOF'
export RBENV_ROOT=/usr/local/rbenv
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

cd $GREENLIGHT_DIR || git clone https://github.com/bigbluebutton/greenlight.git $GREENLIGHT_DIR && cd $GREENLIGHT_DIR

git fetch
git checkout v3
git reset --hard origin/v3

bundle install --deployment --without development test
yarn install --check-files

bundle exec rake db:migrate
bundle exec rake assets:precompile
EOF

echo "===== BBB + Greenlight Full Reinstall Completed Successfully ====="
