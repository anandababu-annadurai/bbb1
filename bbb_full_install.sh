#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter your email address (for Let's Encrypt SSL): " EMAIL
read -sp "Enter password for Greenlight DB user: " GREENLIGHT_DB_PASS
echo
GREENLIGHT_DIR="/var/www/greenlight"
SERVICE_USER="ubuntu"

echo "Domain: $DOMAIN"
echo "Email: $EMAIL"

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev wget

# ======== REMOVE OLD BRIGHTBOX PPA ========
sudo rm -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-*.list
sudo apt update

# ======== HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname "$DOMAIN"
echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton via official script..."
set +e
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s "$DOMAIN" -e "$EMAIL" -g
BBB_STATUS=$?
set -e
if [ $BBB_STATUS -ne 0 ]; then
    echo "⚠️  BBB installation failed. Do you want to run rollback? (y/n)"
    read -r RUN_ROLLBACK
    if [[ "$RUN_ROLLBACK" =~ ^[Yy]$ ]]; then
        sudo bbb-conf --rollback
        echo "Rollback complete. Exiting."
        exit 1
    else
        echo "Skipping rollback. Exiting."
        exit 1
    fi
fi

# ======== INSTALL ADDITIONAL DEPENDENCIES ========
echo "[4] Installing Nginx, PostgreSQL, Node.js, Yarn..."
sudo apt install -y nginx postgresql postgresql-contrib nodejs
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/yarn.gpg
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt update
sudo apt install -y yarn

# ======== INSTALL RBENV & RUBY ========
echo "[5] Installing rbenv and Ruby 3.3.6..."
if [ ! -d "/home/$SERVICE_USER/.rbenv" ]; then
    sudo -u "$SERVICE_USER" git clone https://github.com/rbenv/rbenv.git /home/$SERVICE_USER/.rbenv
    sudo -u "$SERVICE_USER" bash -c "cd /home/$SERVICE_USER/.rbenv && src/configure && make -C src"
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' | sudo tee -a /home/$SERVICE_USER/.bashrc
    echo 'eval "$(rbenv init -)"' | sudo tee -a /home/$SERVICE_USER/.bashrc
    sudo -u "$SERVICE_USER" git clone https://github.com/rbenv/ruby-build.git /home/$SERVICE_USER/.rbenv/plugins/ruby-build
fi
export PATH="/home/$SERVICE_USER/.rbenv/bin:$PATH"
eval "$(rbenv init -)"
sudo -u "$SERVICE_USER" rbenv install -s 3.3.6
sudo -u "$SERVICE_USER" rbenv global 3.3.6
sudo -u "$SERVICE_USER" ruby -v
sudo -u "$SERVICE_USER" gem install bundler

# ======== INSTALL GREENLIGHT ========
echo "[6] Installing Greenlight..."
sudo mkdir -p /var/www
if [ ! -d "$GREENLIGHT_DIR" ]; then
    sudo -u "$SERVICE_USER" git clone https://github.com/bigbluebutton/greenlight.git "$GREENLIGHT_DIR"
fi
cd "$GREENLIGHT_DIR"
sudo -u "$SERVICE_USER" rbenv local 3.3.6
sudo -u "$SERVICE_USER" bundle install
sudo -u "$SERVICE_USER" yarn install

# ======== DATABASE CONFIG ========
echo "[7] Configuring PostgreSQL database..."
sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$GREENLIGHT_DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight;" || true
sudo -u "$SERVICE_USER" bundle exec rake db:migrate

# ======== GREENLIGHT CONFIG ========
echo "[8] Generating Greenlight secrets..."
SECRET_KEY=$(sudo -u "$SERVICE_USER" bundle exec rake secret)
BBB_SECRET=$(bbb-conf --secret)
cat > "$GREENLIGHT_DIR/config/application.yml" <<EOL
SECRET_KEY_BASE: $SECRET_KEY
BIGBLUEBUTTON_ENDPOINT: https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET: $BBB_SECRET
EOL

# ======== FIREWALL ========
echo "[9] Configuring firewall..."
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3478/tcp
sudo ufw allow 5222:5223/tcp
sudo ufw allow 16384:32768/udp
sudo ufw --force enable

# ======== NGINX CONFIG ========
echo "[10] Setting up Nginx reverse proxy..."
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
        proxy_set_header X-Forwarded-Ssl on;
    }
}
EOL
sudo ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# ======== SYSTEMD SERVICE FOR GREENLIGHT ========
echo "[11] Creating systemd service for Greenlight..."
sudo tee /etc/systemd/system/greenlight.service > /dev/null <<EOL
[Unit]
Description=Greenlight Rails server
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$GREENLIGHT_DIR
Environment="PATH=/home/$SERVICE_USER/.rbenv/shims:/home/$SERVICE_USER/.rbenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=/home/$SERVICE_USER/.rbenv/shims/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight.service
sudo systemctl start greenlight.service

# ======== SSL WITH CERTBOT ========
echo "[12] Installing Certbot and enabling SSL..."
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

# ======== AUTOMATIC MAINTENANCE SCRIPT ========
echo "[13] Creating automatic maintenance script..."
sudo tee /usr/local/bin/bbb_maintenance.sh > /dev/null <<'MAINTENANCE'
#!/bin/bash
set -e
DOMAIN="'$DOMAIN'"
GREENLIGHT_DIR="'$GREENLIGHT_DIR'"
EMAIL="'$EMAIL'"

sudo apt update && sudo apt upgrade -y
sudo apt install --only-upgrade -y bigbluebutton

if [ -d "$GREENLIGHT_DIR" ]; then
    cd "$GREENLIGHT_DIR"
    git pull origin main
    gem install bundler
    bundle install
    yarn install
    bundle exec rake db:migrate
    sudo systemctl restart greenlight.service
fi

sudo certbot renew --quiet
sudo systemctl reload nginx

bbb-conf --check
MAINTENANCE

sudo chmod +x /usr/local/bin/bbb_maintenance.sh
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/bbb_maintenance.sh >> /var/log/bbb_maintenance.log 2>&1") | crontab -

# ======== FINAL CHECK ========
echo "[14] Running final BBB check..."
bbb-conf --check

echo "===== Installation Complete! ====="
echo "Greenlight URL: https://$DOMAIN"
echo "Greenlight systemd service: sudo systemctl status greenlight.service"
echo "Maintenance script runs every Sunday at 3 AM."
echo "Full log: $LOG_FILE"
