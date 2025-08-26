#!/bin/bash
set -e

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter your email address (for Let's Encrypt SSL): " EMAIL
read -sp "Enter password for Greenlight DB user: " GREENLIGHT_DB_PASS
echo
GREENLIGHT_DIR="/var/www/greenlight"

echo "===== Starting BBB + Greenlight Full Installation ====="
echo "Domain: $DOMAIN"
echo "Email: $EMAIL"

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential zlib1g-dev lsb-release ufw

# ======== HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton via official script..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ======== INSTALL DEPENDENCIES ========
echo "[4] Installing additional dependencies (PostgreSQL, Ruby, Node.js, Yarn, Nginx)..."
sudo apt install -y nginx postgresql postgresql-contrib ruby-full nodejs
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt update
sudo apt install -y yarn

# ======== INSTALL GREENLIGHT ========
echo "[5] Installing Greenlight manually (optional if not installed by script)..."
cd /var/www
if [ ! -d greenlight ]; then
    sudo git clone https://github.com/bigbluebutton/greenlight.git
fi
cd greenlight
sudo gem install bundler
bundle install
yarn install

# ======== DATABASE CONFIG ========
echo "[6] Configuring PostgreSQL database..."
sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$GREENLIGHT_DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight;"
bundle exec rake db:migrate

# ======== GREENLIGHT CONFIG ========
echo "[7] Generating secrets..."
SECRET_KEY=$(bundle exec rake secret)
BBB_SECRET=$(bbb-conf --secret)
cat > config/application.yml <<EOL
SECRET_KEY_BASE: $SECRET_KEY
BIGBLUEBUTTON_ENDPOINT: https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET: $BBB_SECRET
EOL

# ======== FIREWALL ========
echo "[8] Configuring firewall..."
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3478/tcp
sudo ufw allow 5222:5223/tcp
sudo ufw allow 16384:32768/udp
sudo ufw --
