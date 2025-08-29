#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter PostgreSQL DB password for Greenlight: " DB_PASS

GREENLIGHT_USER="greenlight"
GREENLIGHT_DB_PASS="$DB_PASS"
GREENLIGHT_DIR="/var/www/greenlight"

# ======== UPDATE SYSTEM ========
echo "[1] Updating system packages..."
sudo apt update -y
sudo apt upgrade -y

# ======== INSTALL DEPENDENCIES ========
echo "[2] Installing dependencies..."
sudo apt install -y curl gnupg build-essential git \
  libssl-dev libreadline-dev zlib1g-dev \
  libpq-dev postgresql postgresql-contrib \
  nginx software-properties-common ufw

# ======== CHECK/INSTALL NODE ========
if command -v node >/dev/null 2>&1; then
    echo "[3] Node.js already installed: $(node -v)"
else
    echo "[3] Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
    sudo apt install -y nodejs
fi

if command -v yarn >/dev/null 2>&1; then
    echo "[3] Yarn already installed: $(yarn -v)"
else
    echo "[3] Installing Yarn..."
    sudo npm install -g yarn
fi

# ======== INSTALL rbenv + RUBY ========
if command -v ruby >/dev/null 2>&1 && [[ "$(ruby -v)" == *"3.1.6"* ]]; then
    echo "[4] Ruby 3.1.6 already installed: $(ruby -v)"
else
    echo "[4] Installing rbenv + Ruby 3.1.6..."
    # Install rbenv
    if [ ! -d "$HOME/.rbenv" ]; then
        git clone https://github.com/rbenv/rbenv.git ~/.rbenv
        git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
        echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
        echo 'eval "$(rbenv init -)"' >> ~/.bashrc
        export PATH="$HOME/.rbenv/bin:$PATH"
        eval "$(rbenv init -)"
    fi

    rbenv install -s 3.1.6
    rbenv global 3.1.6
    gem install bundler --no-document
    rbenv rehash
fi

# ======== CONFIGURE BBB REPO FOR FOCAL ========
echo "[5] Adding BigBlueButton repository..."
sudo rm -f /usr/share/keyrings/bbb.gpg
curl -fsSL https://ubuntu.bigbluebutton.org/repo/bbb.gpg | sudo gpg --dearmor -o /usr/share/keyrings/bbb.gpg
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | \
    sudo tee /etc/apt/sources.list.d/bbb.list
sudo apt update

# ======== INSTALL BBB ========
echo "[6] Installing BigBlueButton..."
sudo apt install -y bigbluebutton

# ======== CONFIGURE POSTGRESQL ========
echo "[7] Configuring PostgreSQL..."
sudo systemctl enable postgresql
sudo systemctl start postgresql

sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$GREENLIGHT_USER') THEN CREATE ROLE $GREENLIGHT_USER LOGIN PASSWORD '$GREENLIGHT_DB_PASS'; END IF; END \$\$;"
sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'greenlight_production') THEN CREATE DATABASE greenlight_production OWNER $GREENLIGHT_USER; END IF; END \$\$;"

# ======== INSTALL GREENLIGHT ========
echo "[8] Installing Greenlight..."
if [ ! -d "$GREENLIGHT_DIR" ]; then
    sudo git clone -b v3 https://github.com/bigbluebutton/greenlight.git $GREENLIGHT_DIR
    sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR
fi

cd $GREENLIGHT_DIR
sudo -u $GREENLIGHT_USER bash -c "
export PATH=\"$HOME/.rbenv/shims:\$PATH\"
bundle install
bundle exec rake db:setup RAILS_ENV=production
"

# ======== CONFIGURE NGINX + SSL ========
echo "[9] Configuring Nginx and SSL..."
sudo ufw allow 'OpenSSH'
sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable

sudo tee /etc/nginx/sites-available/greenlight <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    root $GREENLIGHT_DIR/public;

    location / {
        try_files \$uri @app;
    }

    location @app {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

sudo ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

# Install Certbot for Let's Encrypt
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

# ======== CREATE SYSTEMD SERVICE ========
echo "[10] Creating Greenlight systemd service..."
sudo tee /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$GREENLIGHT_USER
Group=$GREENLIGHT_USER
WorkingDirectory=$GREENLIGHT_DIR
Environment=RAILS_ENV=production
Environment=PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:/usr/local/bin:/usr/bin:/bin
ExecStart=$HOME/.rbenv/shims/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl start greenlight

echo "===== Installation Completed Successfully ====="
echo "Greenlight available at: https://$DOMAIN"
