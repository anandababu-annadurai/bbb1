#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -sp "Enter PostgreSQL DB password for Greenlight: " PG_PASSWORD
echo

# ======== VERIFY RUBY ========
if ! command -v ruby >/dev/null 2>&1; then
    echo "[ERROR] Ruby not found. Please install Ruby 3.1.6 via rbenv first."
    exit 1
fi
echo "[INFO] Ruby version: $(ruby -v)"

if ! command -v bundle >/dev/null 2>&1; then
    echo "[INFO] Installing Bundler..."
    gem install bundler --no-document
fi
echo "[INFO] Bundler version: $(bundle -v)"

# ======== VERIFY NODE & NPM ========
if ! command -v node >/dev/null 2>&1; then
    echo "[ERROR] Node.js not found. Please install Node.js 20.x."
    exit 1
fi
echo "[INFO] Node.js version: $(node -v)"

if ! command -v npm >/dev/null 2>&1; then
    echo "[ERROR] npm not found. Please install npm."
    exit 1
fi
echo "[INFO] npm version: $(npm -v)"

# ======== VERIFY YARN ========
if ! command -v yarn >/dev/null 2>&1; then
    echo "[INFO] Installing Yarn..."
    sudo npm install -g yarn --force
fi
echo "[INFO] Yarn version: $(yarn -v || echo 'Yarn not found')"

# ======== UPDATE SYSTEM ========
echo "[1] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl gnupg2 software-properties-common build-essential ufw

# ======== CONFIGURE BBB REPO WITH FIXED GPG ========
echo "[2] Configuring BigBlueButton focal-260 repo..."
sudo rm -f /etc/apt/sources.list.d/bbb.list /etc/apt/sources.list.d/bigbluebutton-focal.list
sudo mkdir -p /usr/share/keyrings

BBB_GPG_URL="https://ubuntu.bigbluebutton.org/focal-260/archive-key.asc"
sudo curl -fsSL $BBB_GPG_URL | sudo tee /usr/share/keyrings/bbb.gpg > /dev/null

echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list

sudo apt-get update -y || echo "[WARNING] BBB repo signature may fail, continuing..."

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton..."
sudo apt-get install -y bigbluebutton

# ======== POSTGRESQL SETUP ========
echo "[4] Configuring PostgreSQL for Greenlight..."
sudo apt-get install -y postgresql postgresql-contrib
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Create Greenlight DB and user
sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$PG_PASSWORD';" || echo "[INFO] User may already exist"
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight;" || echo "[INFO] DB may already exist"

# ======== FIREWALL CONFIG ========
echo "[5] Configuring UFW Firewall..."
sudo ufw allow 22
sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable

# ======== GREENLIGHT INSTALL ========
echo "[6] Installing Greenlight..."
sudo apt-get install -y nginx
git clone https://github.com/bigbluebutton/greenlight.git /var/www/greenlight
cd /var/www/greenlight
bundle install
yarn install --check-files

# Configure Greenlight environment
cp .env.example .env
sed -i "s/DOMAIN=.*/DOMAIN=$DOMAIN/" .env
sed -i "s/DB_PASSWORD=.*/DB_PASSWORD=$PG_PASSWORD/" .env

bundle exec rake db:create
bundle exec rake db:migrate

# ======== SSL SETUP ========
echo "[7] Configuring SSL using Let's Encrypt..."
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m your-email@example.com

echo "===== BBB + Greenlight Installation Completed Successfully ====="
echo "Visit https://$DOMAIN to access Greenlight"
