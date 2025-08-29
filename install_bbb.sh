#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_greenlight_fast.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Fast BBB + Greenlight Installer (Ubuntu 20.04) ====="

read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter PostgreSQL DB password for Greenlight: " DB_PASS

GREENLIGHT_USER="greenlight"
GREENLIGHT_DB_PASS="$DB_PASS"
GREENLIGHT_DIR="/var/www/greenlight"

# ======== REMOVE OLD BBB REPOS ========
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-xenial.list
sudo rm -f /etc/apt/sources.list.d/brightbox-ruby-ng.list

# ======== ADD BBB FOCAL REPO WITH GPG ========
echo "[1] Configuring BigBlueButton Focal repo..."
wget -qO- https://ubuntu.bigbluebutton.org/repo/bigbluebutton.asc | sudo gpg --dearmor -o /usr/share/keyrings/bbb.gpg
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list

sudo apt-get update -y

# ======== INSTALL BBB CORE ========
echo "[2] Installing BigBlueButton core..."
sudo apt-get install -y bigbluebutton

# ======== POSTGRES SETUP ========
echo "[3] Configuring PostgreSQL..."
sudo systemctl enable postgresql
sudo systemctl start postgresql

sudo -u postgres psql <<EOF
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$GREENLIGHT_USER') THEN
      CREATE ROLE $GREENLIGHT_USER LOGIN PASSWORD '$GREENLIGHT_DB_PASS';
   END IF;
END
\$do\$;

DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'greenlight_production') THEN
      CREATE DATABASE greenlight_production OWNER $GREENLIGHT_USER;
   END IF;
END
\$do\$;
EOF

# ======== INSTALL GREENLIGHT ========
echo "[4] Installing Greenlight..."
sudo useradd -m -s /bin/bash $GREENLIGHT_USER 2>/dev/null || true

if [ ! -d "$GREENLIGHT_DIR" ]; then
    sudo git clone https://github.com/bigbluebutton/greenlight.git -b v3 $GREENLIGHT_DIR
    sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR
fi

cd $GREENLIGHT_DIR
sudo -u $GREENLIGHT_USER cp config/database.yml.example config/database.yml
sudo -u $GREENLIGHT_USER sed -i "s/password:.*/password: $GREENLIGHT_DB_PASS/" config/database.yml

# Bundler install
sudo -u $GREENLIGHT_USER bash -c "bundle install"

# DB setup
sudo -u $GREENLIGHT_USER bash -c "RAILS_ENV=production bundle exec rake db:setup"

# ======== NGINX & SSL ========
echo "[5] Configuring Nginx and SSL..."
sudo apt-get install -y nginx certbot python3-certbot-nginx

sudo rm -f /etc/nginx/sites-enabled/default
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
sudo nginx -t
sudo systemctl restart nginx
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

# ======== FIREWALL ========
echo "[6] Configuring firewall..."
sudo ufw allow 'OpenSSH'
sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable

# ======== GREENLIGHT SYSTEMD ========
echo "[7] Creating Greenlight systemd service..."
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
ExecStart=/usr/bin/env bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl start greenlight

echo "===== Fast Installation Completed Successfully ====="
echo "Access Greenlight: https://$DOMAIN"
echo "Check Greenlight status: sudo systemctl status greenlight"
echo "View logs: journalctl -u greenlight -f"
