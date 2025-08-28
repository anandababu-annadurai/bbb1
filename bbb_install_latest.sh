#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Full Non-Interactive Installation Started ====="

# ======== VARIABLES ========
DOMAIN=${DOMAIN:-""}   # Optionally set before running
DB_PASS=${DB_PASS:-"greenlightpass"}  # Default Greenlight DB password

# Automatically detect public IP if DOMAIN not set
if [ -z "$DOMAIN" ]; then
    DOMAIN=$(curl -s ifconfig.me)
    echo "[INFO] No domain provided. Using server public IP: $DOMAIN"
fi

echo "[INFO] Using Greenlight DB password: $DB_PASS"

# ======== FIREWALL SETUP ========
echo "[0] Configuring firewall..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp   # SSH
sudo ufw allow 80/tcp   # HTTP
sudo ufw allow 443/tcp  # HTTPS
sudo ufw allow 16384:32768/udp  # BBB WebRTC
sudo ufw --force enable
echo "✔ Firewall configured"

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt-get update -y && sudo apt-get upgrade -y

# ======== DEPENDENCIES ========
echo "[2] Installing dependencies..."
sudo apt-get install -y build-essential libssl-dev libreadline-dev zlib1g-dev git curl gnupg2 \
                        nginx certbot python3-certbot-nginx postgresql postgresql-contrib

# ======== NODE.JS + YARN ========
echo "[3] Installing Node.js & Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g yarn
echo "✔ Node.js: $(node -v), NPM: $(npm -v), Yarn: $(yarn -v)"

# ======== RUBY VIA RBENV ========
echo "[4] Installing Ruby 3.1.6 via rbenv..."
RBENV_DIR="/var/www/greenlight/.rbenv"
if [ ! -d "$RBENV_DIR" ]; then
    sudo mkdir -p /var/www/greenlight
    sudo git clone https://github.com/rbenv/rbenv.git $RBENV_DIR
    sudo git clone https://github.com/rbenv/ruby-build.git $RBENV_DIR/plugins/ruby-build
    export RBENV_ROOT="$RBENV_DIR"
    export PATH="$RBENV_ROOT/bin:$PATH"
    eval "$(rbenv init -)"
    rbenv install 3.1.6
    rbenv global 3.1.6
else
    echo "✔ Ruby already installed under $RBENV_DIR"
    export RBENV_ROOT="$RBENV_DIR"
    export PATH="$RBENV_ROOT/bin:$PATH"
    eval "$(rbenv init -)"
fi
sudo gem install bundler

# ======== POSTGRESQL SETUP ========
echo "[5] Configuring PostgreSQL..."
sudo -u postgres psql <<EOF
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'greenlight_user') THEN
      CREATE ROLE greenlight_user LOGIN PASSWORD '$DB_PASS';
   END IF;
END
\$do\$;

CREATE DATABASE greenlight_db OWNER greenlight_user;
EOF
echo "✔ PostgreSQL configured"

# ======== GREENLIGHT INSTALL ========
echo "[6] Installing Greenlight..."
cd /var/www
if [ -d "greenlight" ]; then
    sudo rm -rf greenlight
fi
sudo git clone -b v3 https://github.com/bigbluebutton/greenlight.git
cd greenlight
sudo cp config/database.yml.example config/database.yml
sudo sed -i "s/username:.*/username: greenlight_user/" config/database.yml
sudo sed -i "s/password:.*/password: $DB_PASS/" config/database.yml
sudo sed -i "s/database:.*/database: greenlight_db/" config/database.yml

sudo bundle install
sudo yarn install

# Configure .env with BBB API
sudo cp .env.example .env
BBB_ENDPOINT="http://$DOMAIN/bigbluebutton/api"
BBB_SECRET=$(sudo bbb-conf --secret | awk '/Secret/ {print $2}')
sudo sed -i "s|BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$BBB_ENDPOINT|" .env
sudo sed -i "s|BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$BBB_SECRET|" .env
sudo sed -i "s|SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(sudo bundle exec rake secret)|" .env

# Database setup & assets
sudo RAILS_ENV=production bundle exec rake db:setup
sudo RAILS_ENV=production bundle exec rake assets:precompile
echo "✔ Greenlight installed and connected to BBB API at $BBB_ENDPOINT"

# ======== NGINX CONFIG ========
echo "[7] Configuring NGINX..."
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/greenlight/public;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# ======== SSL SETUP ========
echo "[8] Setting up SSL with Certbot..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN || true

# ======== SSL AUTO-RENEW + HSTS ========
echo "[9] Finalizing SSL setup..."
if ! systemctl list-timers | grep -q certbot; then
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -
fi
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
if ! grep -q "Strict-Transport-Security" "$NGINX_CONF"; then
    sudo sed -i '/ssl_certificate_key/a \\tadd_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;' "$NGINX_CONF"
fi
sudo systemctl reload nginx

# ======== GREENLIGHT SYSTEMD SERVICE ========
echo "[10] Creating systemd service for Greenlight..."
sudo tee /etc/systemd/system/greenlight.service > /dev/null <<EOF
[Unit]
Description=Greenlight Rails App
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/var/www/greenlight
Environment=RAILS_ENV=production
ExecStart=/var/www/greenlight/.rbenv/shims/bundle exec rails server -b 127.0.0.1 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl start greenlight

# ======== DONE ========
echo "===== BBB + Greenlight Non-Interactive Installation Completed Successfully ====="
echo "Visit: https://$DOMAIN"
sudo certbot certificates | grep "Expiry"
