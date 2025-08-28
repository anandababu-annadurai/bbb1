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

GREENLIGHT_DIR="/var/www/greenlight"

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall with SSH protection..."
sudo ufw --force reset
sudo ufw allow ssh
sudo ufw allow 22/tcp

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip

# ======== REMOVE OLD RUBY PPA ========
if [ -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list ]; then
    echo "[2] Removing old Brightbox Ruby PPA..."
    sudo rm /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list
fi
sudo apt update

# ======== SET HOSTNAME ========
echo "[3] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[4] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ======== INSTALL NODE & YARN ========
echo "[5] Installing Node.js 20.x and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
npm -v
yarn -v

# ======== INSTALL SYSTEM-WIDE RBENV IF NOT PRESENT ========
if [ ! -d "/usr/local/rbenv" ]; then
    echo "[6] Installing system-wide rbenv..."
    sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    sudo mkdir -p /usr/local/rbenv/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
    sudo chown -R $USER:$USER /usr/local/rbenv
else
    echo "[6] System-wide rbenv already installed. Skipping..."
fi
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

# ======== INSTALL RUBY IF NOT PRESENT ========
RUBY_VERSION="3.1.6"
if ! rbenv versions | grep -q "$RUBY_VERSION"; then
    echo "[7] Installing Ruby $RUBY_VERSION..."
    rbenv install $RUBY_VERSION
else
    echo "[7] Ruby $RUBY_VERSION already installed. Skipping..."
fi
rbenv global $RUBY_VERSION
gem install bundler --no-document

# ======== CONFIGURE POSTGRESQL ========
echo "[8] Configuring PostgreSQL..."
sudo -u postgres psql -c "DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'greenlight_user') THEN
       CREATE ROLE greenlight_user WITH LOGIN PASSWORD '$GREENLIGHT_DB_PASS';
   END IF;
END \$\$;"
sudo -u postgres psql -c "DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'greenlight_production') THEN
       CREATE DATABASE greenlight_production OWNER greenlight_user;
   END IF;
END \$\$;"

# ======== CLONE OR UPDATE GREENLIGHT ========
echo "[9] Installing or upgrading Greenlight..."
if [ ! -d "$GREENLIGHT_DIR/.git" ]; then
    echo "[INFO] Cloning Greenlight repository..."
    sudo mkdir -p $GREENLIGHT_DIR
    sudo chown -R $USER:$USER $GREENLIGHT_DIR
    git clone -b v3 https://github.com/bigbluebutton/greenlight.git $GREENLIGHT_DIR
else
    echo "[INFO] Updating existing Greenlight repo..."
    cd $GREENLIGHT_DIR
    git fetch origin v3
    git reset --hard origin/v3
fi

cd $GREENLIGHT_DIR

# ======== PATCH PRODUCTION.RB LOGGER ISSUE ========
PROD_FILE="$GREENLIGHT_DIR/config/environments/production.rb"
if [ -f "$PROD_FILE" ]; then
    if ! grep -q "config.logger ||= ActiveSupport::Logger.new" "$PROD_FILE"; then
        sed -i "/Rails.application.configure do/a \\
config.logger ||= ActiveSupport::Logger.new(\$stdout)\\
config.log_formatter = ::Logger::Formatter.new\\
config.logger.formatter = config.log_formatter" "$PROD_FILE"
        echo "[INFO] production.rb patched successfully."
    fi
fi

# ======== COPY CONFIG FILES ========
if [ ! -f "config/database.yml" ]; then
    cp config/database.yml.example config/database.yml || echo "[WARN] database.yml.example not found, creating default"
fi
if [ ! -f ".env" ]; then
    cp .env.example .env || echo "[WARN] .env.example not found, creating default .env"
fi

# ======== INSTALL DEPENDENCIES ========
bundle config set path 'vendor/bundle'
bundle install --without development test
yarn install

# ======== PRECOMPILE ASSETS ========
bundle exec rake db:migrate RAILS_ENV=production
bundle exec rake assets:precompile RAILS_ENV=production

echo "===== Installation Complete! ====="
echo "✔ Greenlight available at https://$DOMAIN"
