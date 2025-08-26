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

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    wget

# ======== REMOVE OLD BRIGHTBOX PPA ========
if [ -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list ]; then
    echo "[2] Removing old Brightbox Ruby PPA..."
    sudo rm -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list
fi
sudo apt update

# ======== HOSTNAME ========
echo "[3] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts

# ======== INSTALL BIGBLUEBUTTON ========
echo "[4] Installing BigBlueButton via official script..."
if ! wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s "$DOMAIN" -e "$EMAIL" -g; then
    read -p "⚠️  Installation failed. Run rollback? (y/n): " ROLLBACK
    if [[ "$ROLLBACK" == "y" || "$ROLLBACK" == "Y" ]]; then
        sudo bbb-install.sh --rollback
    fi
    exit 1
fi

# ======== INSTALL ADDITIONAL DEPENDENCIES ========
echo "[5] Installing Nginx, PostgreSQL, Node.js, Yarn..."
sudo apt install -y nginx postgresql postgresql-contrib nodejs
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/yarn.gpg
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt update
sudo apt install -y yarn

# ======== INSTALL SYSTEM-WIDE RBENV & RUBY 3.3.6 ========
echo "[6] Installing rbenv system-wide and Ruby 3.3.6..."
if [ ! -d "/usr/local/rbenv" ]; then
    sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    sudo mkdir -p /usr/local/rbenv/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
    echo 'export RBENV_ROOT="/usr/local/rbenv"' | sudo tee /etc/profile.d/rbenv.sh
    echo 'export PATH="$RBENV_ROOT/bin:$PATH"' | sudo tee -a /etc/profile.d/rbenv.sh
    echo 'eval "$(rbenv init -)"' | sudo tee -a /etc/profile.d/rbenv.sh
    sudo chmod +x /etc/profile.d/rbenv.sh
fi

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

sudo -E rbenv install -s 3.3.6
sudo -E rbenv global 3.3.6
sudo -E gem install bundler
ruby -v
gem -v

# ======== INSTALL GREENLIGHT ========
echo "[7] Installing Greenlight..."
sudo mkdir -p /var/www
cd /var/www
if [ ! -d greenlight ]; then
    sudo git clone https://github.com/bigbluebutton/greenlight.git
fi
cd greenlight
sudo -E rbenv local 3.3.6
sudo -E gem install bundler
sudo -E bundle install
sudo -E yarn install

# ======== DATABASE CONFIG ========
echo "[8] Configuring PostgreSQL database..."
sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$GREENLIGHT_DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight;" || true
sudo -E bundle exec rake db:migrate

# ======== GREENLIGHT CONFIG ========
echo "[9] Generating Greenlight secrets..."
SECRET_KEY=$(sudo -E bundle exec rake secret)
BBB_SECRET=$(sudo bbb-conf --secret)
sudo tee config/application.yml > /dev/null <<EOL
SECRET_KEY_BASE: $SECRET_KEY
BIGBLUEBUTTON_ENDPOINT: https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET: $BBB_SECRET
EOL

# ======== FIREWALL ========
echo "[10] Configuring firewall..."
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3478/tcp
sudo ufw allow 5222:5223/tcp
sudo ufw allow 16384:32768/udp
sudo ufw --force enable

# ======== NGINX CONFIG ========
echo "[11] Setting up Nginx reverse proxy..."
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
echo "[12] Creating systemd service for Greenlight..."
sudo tee /etc/systemd/system/greenlight.service > /dev/null <<EOL
[Unit]
Description=Greenlight Rails server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$GREENLIGHT_DIR
ExecStart=/usr/local/rbenv/shims/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
EOL
sudo systemctl daemon-reload
sudo systemctl enable greenlight.service
sudo systemctl start greenlight.service

# ======== SSL WITH CERTBOT ========
echo "[13] Installing Certbot and enabling SSL..."
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

# ======== AUTOMATIC MAINTENANCE SCRIPT ========
echo "[14] Creating automatic maintenance script..."
sudo tee /usr/local/bin/bbb_maintenance.sh > /dev/null <<'MAINTENANCE'
#!/bin/bash
set -e
DOMAIN="'$DOMAIN'"
GREENLIGHT_DIR="'$GREENLIGHT_DIR'"
EMAIL="'$EMAIL'"

echo "===== Running BBB + Greenlight Maintenance ====="

sudo apt update && sudo apt upgrade -y
sudo apt install --only-upgrade -y bigbluebutton

if [ -d "$GREENLIGHT_DIR" ]; then
    cd "$GREENLIGHT_DIR"
    git pull origin main
    sudo -E gem install bundler
    sudo -E bundle install
    sudo -E yarn install
    sudo -E bundle exec rake db:migrate
    sudo systemctl restart greenlight.service
fi

sudo certbot renew --quiet
sudo systemctl reload nginx

bbb-conf --check
MAINTENANCE

sudo chmod +x /usr/local/bin/bbb_maintenance.sh

# ======== SETUP WEEKLY CRON FOR MAINTENANCE ========
echo "[15] Setting up weekly cron job for automatic maintenance..."
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/bbb_maintenance.sh >> /var/log/bbb_maintenance.log 2>&1") | crontab -

# ======== FINAL CHECK ========
echo "[16] Running final BBB check..."
sudo bbb-conf --check

echo "===== Installation Complete! ====="
echo "Greenlight URL: https://$DOMAIN"
echo "Greenlight systemd service: systemctl status greenlight.service"
echo "Maintenance script runs every Sunday at 3 AM."
echo "Full log saved to $LOG_FILE"
