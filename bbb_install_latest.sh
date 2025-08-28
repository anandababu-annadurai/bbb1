#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ===============================
# User Input
# ===============================
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email address for SSL [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [greenlight_pass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlight_pass}
echo

# ===============================
# Non-root user for Greenlight
# ===============================
GREENLIGHT_USER=greenlight
GREENLIGHT_DIR="/var/www/greenlight"

if ! id -u $GREENLIGHT_USER >/dev/null 2>&1; then
    sudo useradd -m -s /bin/bash $GREENLIGHT_USER
fi

sudo mkdir -p $GREENLIGHT_DIR
sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR

# ===============================
# System Update & Dependencies
# ===============================
echo "[1] Updating system and installing dependencies..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
 zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
 postgresql postgresql-contrib redis-server nginx unzip zip nodejs npm yarn

# ===============================
# Firewall
# ===============================
echo "[2] Configuring firewall..."
sudo ufw --force reset
sudo ufw allow ssh
sudo ufw allow 22/tcp
sudo ufw enable

# ===============================
# Hostname
# ===============================
sudo hostnamectl set-hostname $DOMAIN
grep -q "$DOMAIN" /etc/hosts || echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts

# ===============================
# BigBlueButton Installation
# ===============================
echo "[3] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ===============================
# rbenv & Ruby Setup (per-user)
# ===============================
echo "[4] Setting up rbenv and Ruby 3.1.6..."
sudo -u $GREENLIGHT_USER -i bash <<'EOF'
RBENV_ROOT="$HOME/.rbenv"
if [ ! -d "$RBENV_ROOT" ]; then
    git clone https://github.com/rbenv/rbenv.git $RBENV_ROOT
    cd $RBENV_ROOT && src/configure && make -C src
    mkdir -p $RBENV_ROOT/plugins
    git clone https://github.com/rbenv/ruby-build.git $RBENV_ROOT/plugins/ruby-build
fi
export RBENV_ROOT="$RBENV_ROOT"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"
RUBY_VERSION="3.1.6"
if ! rbenv versions | grep -q $RUBY_VERSION; then
    rbenv install $RUBY_VERSION
fi
rbenv global $RUBY_VERSION
gem install bundler --no-document
EOF

# ===============================
# PostgreSQL Setup
# ===============================
echo "[5] Configuring PostgreSQL..."
sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='greenlight_user') THEN CREATE ROLE greenlight_user LOGIN PASSWORD '$GREENLIGHT_DB_PASS'; END IF; END\$\$;"
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight_user;" || echo "[INFO] Database already exists"

# ===============================
# Greenlight Installation/Upgrade
# ===============================
echo "[6] Installing or updating Greenlight..."
sudo -u $GREENLIGHT_USER -i bash <<'EOF'
GREENLIGHT_DIR="$HOME/greenlight"
cd $HOME
if [ ! -d "$GREENLIGHT_DIR/.git" ]; then
    git clone https://github.com/bigbluebutton/greenlight.git greenlight
fi
cd $GREENLIGHT_DIR
git fetch
git checkout v3
git reset --hard origin/v3

# Ensure correct Ruby version
echo "3.1.6" > .ruby-version
eval "$(rbenv init -)"
rbenv local 3.1.6

# Install Gems
bundle config set --local path 'vendor/bundle'
bundle install

# Yarn install
yarn install --check-files

# Create default .env if missing
[ ! -f .env ] && cp .env.example .env 2>/dev/null || touch .env

# Fix logger nil issue in production.rb
sed -i "s/logger.formatter = config.log_formatter/if logger; logger.formatter = config.log_formatter; end/" config/environments/production.rb

RAILS_ENV=production bundle exec rake db:create db:migrate db:seed
RAILS_ENV=production bundle exec rake assets:precompile
EOF

# ===============================
# Systemd Service
# ===============================
echo "[7] Creating systemd service for Greenlight..."
sudo tee /etc/systemd/system/greenlight.service >/dev/null <<EOL
[Unit]
Description=Greenlight Puma Server
After=network.target

[Service]
Type=simple
User=$GREENLIGHT_USER
WorkingDirectory=$GREENLIGHT_DIR
Environment=RAILS_ENV=production
ExecStart=$GREENLIGHT_DIR/.rbenv/shims/bundle exec puma -C config/puma.rb
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl restart greenlight

# ===============================
# Nginx + SSL
# ===============================
echo "[8] Configuring Nginx for $DOMAIN..."
sudo tee /etc/nginx/sites-available/greenlight >/dev/null <<EOL
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

# SSL
echo "[9] Issuing SSL certificate..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "✅ Greenlight installed and secured with HTTPS at https://$DOMAIN"
