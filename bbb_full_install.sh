#!/bin/bash
set -e

# ======== CONFIGURATION ========
DOMAIN="bbb.example.com"           # Change this to your domain
GREENLIGHT_DB_PASS="GreenlightPass123"  # Change this password
EMAIL="your-email@example.com"     # For Let's Encrypt
GREENLIGHT_DIR="/var/www/greenlight"

echo "===== Starting BBB + Greenlight Full Installation ====="

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
apt update && apt upgrade -y
apt install -y software-properties-common curl git gnupg2 build-essential zlib1g-dev lsb-release ufw

# ======== HOSTNAME ========
echo "[2] Setting hostname..."
hostnamectl set-hostname $DOMAIN
echo "127.0.0.1 $DOMAIN" >> /etc/hosts

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton..."
add-apt-repository ppa:bigbluebutton/support -y
apt update
apt install -y bigbluebutton

# ======== INSTALL DEPENDENCIES ========
echo "[4] Installing Nginx, PostgreSQL, Node.js, Yarn, Ruby..."
apt install -y nginx postgresql postgresql-contrib ruby-full nodejs
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add -
echo "deb https://dl.yarnpkg.com/debian/ stable main" | tee /etc/apt/sources.list.d/yarn.list
apt update
apt install -y yarn

# ======== INSTALL GREENLIGHT ========
echo "[5] Installing Greenlight..."
cd /var/www
git clone https://github.com/bigbluebutton/greenlight.git
cd greenlight
gem install bundler
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
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3478/tcp
ufw allow 5222:5223/tcp
ufw allow 16384:32768/udp
ufw --force enable

# ======== NGINX CONFIG ========
echo "[9] Setting up Nginx reverse proxy..."
cat > /etc/nginx/sites-available/greenlight <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root $GREENLIGHT_DIR/public;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Ssl on;
    }
}
EOL
ln -s /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# ======== SYSTEMD SERVICE FOR GREENLIGHT ========
echo "[10] Creating systemd service for Greenlight..."
cat > /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight Rails server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$GREENLIGHT_DIR
ExecStart=/usr/bin/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable greenlight.service
systemctl start greenlight.service

# ======== SSL WITH CERTBOT ========
echo "[11] Installing Certbot and enabling SSL..."
apt install -y certbot python3-certbot-nginx
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

# ======== CREATE AUTOMATIC MAINTENANCE SCRIPT ========
echo "[12] Creating automatic maintenance script..."
cat > /usr/local/bin/bbb_maintenance.sh <<'MAINTENANCE'
#!/bin/bash
set -e
DOMAIN="bbb.example.com"
GREENLIGHT_DIR="/var/www/greenlight"
EMAIL="your-email@example.com"

echo "===== Running BBB + Greenlight Maintenance ====="

# Update system packages
apt update && apt upgrade -y

# Update BBB
apt install --only-upgrade -y bigbluebutton

# Update Greenlight
if [ -d "$GREENLIGHT_DIR" ]; then
    cd $GREENLIGHT_DIR
    git pull origin main
    gem install bundler
    bundle install
    yarn install
    bundle exec rake db:migrate
    systemctl restart greenlight.service
fi

# Renew SSL
certbot renew --quiet
systemctl reload nginx

# BBB check
bbb-conf --check
MAINTENANCE

chmod +x /usr/local/bin/bbb_maintenance.sh

# ======== SETUP CRON FOR WEEKLY MAINTENANCE ========
echo "[13] Setting up weekly cron job for automatic maintenance..."
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/bbb_maintenance.sh >> /var/log/bbb_maintenance.log 2>&1") | crontab -

# ======== FINAL CHECK ========
echo "[14] Running final BBB check..."
bbb-conf --check

echo "===== Installation & Maintenance Setup Complete! ====="
echo "Greenlight URL: https://$DOMAIN"
echo "Greenlight systemd service: systemctl status greenlight.service"
echo "Maintenance script runs automatically every Sunday at 3 AM."
