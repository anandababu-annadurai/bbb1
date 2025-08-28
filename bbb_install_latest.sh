#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Fully Automated Installer ====="

# ======== USER INPUT WITH DEFAULTS ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter email for Let's Encrypt SSL [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

GREENLIGHT_DIR="/var/www/greenlight"

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall..."
sudo ufw --force reset
sudo ufw allow ssh
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip nodejs yarn

# ======== SET HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ======== INSTALL SYSTEM-WIDE RBENV & RUBY ========
echo "[4] Installing Ruby 3.1.6 via system-wide rbenv..."
if [ ! -d "/usr/local/rbenv" ]; then
    sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    cd /usr/local/rbenv && sudo src/configure && sudo make -C src
    sudo mkdir -p /usr/local/rbenv/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
fi
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

if ! rbenv versions | grep -q "3.1.6"; then
    rbenv install 3.1.6
fi
rbenv global 3.1.6
gem install bundler
rbenv rehash

# ======== CONFIGURE POSTGRESQL SAFELY ========
echo "[5] Configuring PostgreSQL..."
sudo -u postgres psql -c "DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='greenlight_user') THEN
      CREATE ROLE greenlight_user WITH PASSWORD '$GREENLIGHT_DB_PASS';
   END IF;
END \$\$;"

sudo -u postgres psql -c "DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname='greenlight_production') THEN
      CREATE DATABASE greenlight_production OWNER greenlight_user;
   END IF;
END \$\$;"

# ======== GREENLIGHT INSTALL / UPGRADE ========
echo "[6] Installing/upgrading Greenlight..."
sudo mkdir -p $GREENLIGHT_DIR
cd $GREENLIGHT_DIR

if [ ! -d ".git" ]; then
    sudo rm -rf *
    git clone -b v3 https://github.com/bigbluebutton/greenlight.git .
else
    git fetch origin
    git checkout v3
    git reset --hard origin/v3
fi

# Force correct Ruby version
echo "3.1.6" > .ruby-version
rbenv rehash

# ======== HANDLE .env ========
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo "[INFO] Copied .env.example to .env"
    else
        touch .env
        echo "[WARN] .env.example not found, created empty .env"
    fi
fi

# Fetch BBB secret
BBB_CONF="/usr/local/bin/bbb-conf"
BBB_SECRET=""
if [ -x "$BBB_CONF" ]; then
    BBB_SECRET=$($BBB_CONF --secret | awk '/Secret/ {print $2}')
fi
BBB_ENDPOINT="http://$DOMAIN/bigbluebutton/api"
RAILS_SECRET=$(RAILS_ENV=production bundle exec rake secret || true)

# Update .env safely
grep -q "BIGBLUEBUTTON_ENDPOINT" .env && sed -i "s|BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BBB_ENDPOINT|" .env || echo "BIGBLUEBUTTON_ENDPOINT=$BBB_ENDPOINT" >> .env
grep -q "BIGBLUEBUTTON_SECRET" .env && sed -i "s|BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$BBB_SECRET|" .env || echo "BIGBLUEBUTTON_SECRET=$BBB_SECRET" >> .env
grep -q "SECRET_KEY_BASE" .env && sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$RAILS_SECRET|" .env || echo "SECRET_KEY_BASE=$RAILS_SECRET" >> .env

# ======== INSTALL DEPENDENCIES ========
bundle config set --local path 'vendor/bundle'
bundle install
yarn install
RAILS_ENV=production bundle exec rake db:migrate
RAILS_ENV=production bundle exec rake assets:precompile

# ======== SETUP SYSTEMD SERVICE ========
echo "[7] Creating systemd service for Greenlight..."
sudo tee /etc/systemd/system/greenlight.service > /dev/null <<EOL
[Unit]
Description=Greenlight Puma Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$GREENLIGHT_DIR
Environment=RAILS_ENV=production
ExecStart=$RBENV_ROOT/shims/bundle exec puma -C config/puma.rb
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl restart greenlight

# ======== NGINX + SSL ========
echo "[8] Configuring Nginx for $DOMAIN..."
sudo tee /etc/nginx/sites-available/greenlight > /dev/null <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root $GREENLIGHT_DIR/public;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

sudo ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/greenlight
sudo nginx -t && sudo systemctl restart nginx
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "✅ BigBlueButton + Greenlight fully installed at https://$DOMAIN"
