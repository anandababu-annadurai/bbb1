#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email address (for SSL) [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

GREENLIGHT_DIR="/var/www/greenlight"
GREENLIGHT_USER="${USER}"  # You can change to a dedicated user if needed
RUBY_VERSION="3.1.6"

# ======== FIREWALL ========
echo "[0] Configuring firewall..."
sudo ufw --force reset
sudo ufw allow ssh
sudo ufw allow 22/tcp
sudo ufw enable

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip nodejs npm yarn

# ======== HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname "$DOMAIN"
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s "$DOMAIN" -e "$EMAIL" -g

# ======== RBENV & RUBY ========
echo "[4] Setting up rbenv and Ruby..."
if [ ! -d "/usr/local/rbenv" ]; then
    sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    sudo mkdir -p /usr/local/rbenv/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
    sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER /usr/local/rbenv
fi

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

if ! rbenv versions | grep -q "$RUBY_VERSION"; then
    echo "[INFO] Installing Ruby $RUBY_VERSION..."
    rbenv install "$RUBY_VERSION"
fi

rbenv global "$RUBY_VERSION"
gem install bundler --no-document

# ======== PostgreSQL Setup ========
echo "[5] Configuring PostgreSQL..."
sudo -u postgres psql -c "DO \$\$ BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'greenlight_user') THEN
      CREATE ROLE greenlight_user WITH LOGIN PASSWORD '$GREENLIGHT_DB_PASS';
   END IF;
END \$\$;"
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight_user;" || echo "Database already exists"

# ======== Greenlight Installation ========
echo "[6] Installing/upgrading Greenlight..."
sudo mkdir -p "$GREENLIGHT_DIR"
sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER "$GREENLIGHT_DIR"

sudo -u $GREENLIGHT_USER bash <<EOF
cd "$GREENLIGHT_DIR"
if [ ! -d ".git" ]; then
    git clone https://github.com/bigbluebutton/greenlight.git .
    git checkout v3
else
    git fetch origin
    git checkout v3
    git reset --hard origin/v3
fi

# Ensure .ruby-version is correct
echo "$RUBY_VERSION" > .ruby-version
rbenv rehash
rbenv shell $RUBY_VERSION

# Install gems and JS dependencies
bundle install --path vendor/bundle
yarn install

# Generate secret key
SECRET_KEY=\$(bundle exec rake secret)
grep -q "SECRET_KEY_BASE" .env && sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=\$SECRET_KEY|" .env || echo "SECRET_KEY_BASE=\$SECRET_KEY" >> .env

# Setup database and precompile assets
RAILS_ENV=production bundle exec rake db:create db:migrate db:seed
RAILS_ENV=production bundle exec rake assets:precompile
EOF

# ======== Puma & Systemd ========
echo "[7] Creating systemd service..."
cat | sudo tee /etc/systemd/system/greenlight.service > /dev/null <<EOL
[Unit]
Description=Greenlight Puma Server
After=network.target

[Service]
Type=simple
User=$GREENLIGHT_USER
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
sudo systemctl start greenlight

# ======== Nginx & SSL ========
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

echo "[9] Issuing SSL certificate..."
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

echo "✅ Greenlight installed and secured with HTTPS at https://$DOMAIN"
