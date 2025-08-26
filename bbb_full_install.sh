#!/bin/bash
set -e

LOGFILE="$HOME/bbb_install.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="
echo "Logging to $LOGFILE"

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
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev wget

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
echo "Output will be logged to $LOGFILE"
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s "$DOMAIN" -e "$EMAIL" -g

# ======== ADDITIONAL DEPENDENCIES ========
echo "[5] Installing Nginx, PostgreSQL, Node.js, Yarn..."
sudo apt install -y nginx postgresql postgresql-contrib nodejs
curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/yarn.gpg
echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
sudo apt update
sudo apt install -y yarn

# ======== RUBY 3.3.6 INSTALLATION VIA RBENV ========
echo "[6] Installing Ruby 3.3.6 via rbenv..."
if [ ! -d "$HOME/.rbenv" ]; then
    git clone https://github.com/rbenv/rbenv.git ~/.rbenv
    cd ~/.rbenv && src/configure && make -C src
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
    echo 'eval "$(rbenv init -)"' >> ~/.bashrc
    source ~/.bashrc
    git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
    export PATH="$HOME/.rbenv/plugins/ruby-build/bin:$PATH"
fi
rbenv install -s 3.3.6
rbenv global 3.3.6
ruby -v
gem -v

# ======== INSTALL GREENLIGHT ========
echo "[7] Installing Greenlight..."
cd /var/www
if [ ! -d greenlight ]; then
    sudo git clone https://github.com/bigbluebutton/greenlight.git
fi
cd greenlight
rbenv local 3.3.6
gem install bundler
bundle install
yarn install

# ======== DATABASE CONFIG ========
echo "[8] Configuring PostgreSQL database..."
sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$GREENLIGHT_DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight;" || true
bundle exec rake db:migrate

# ======== GREENLIGHT CONFIG ========
echo "[9] Generating Greenlight secrets..."
SECRET_KEY=$(bundle exec rake secret)
BBB_SECRET=$(bbb-conf --secret)
cat > config/application.yml <<EOL
SECRET_KEY_BASE: $SECRET_KEY
BIGBLUEBUTTON_ENDPOINT: https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET: $BBB_SECRET
EOL

# ======== FIREWALL ========
echo "[10] Configuring firewall..."
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3478/tcp
sudo ufw allow 5222:5223/tcp
sudo ufw allow 16384:32768/udp
sudo ufw --force enable

# ======== NGINX CONFIG ========
echo "[11] Setting up Nginx reverse proxy..."
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
sudo ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# ======== SYSTEMD SERVICE FOR GREENLIGHT ========
echo "[12] Creating systemd service for Greenlight..."
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
sudo systemctl daemon-reload
sudo systemctl enable greenlight.service
sudo systemctl start greenlight.service

# ======== SSL WITH CERTBOT ========
echo "[13] Installing Certbot and enabling SSL..."
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL"

# ======== AUTOMATIC MAINTENANCE SCRIPT ========
echo "[14] Creating automatic maintenance script..."
cat > /usr/local/bin/bbb_maintenance.sh <<'MAINTENANCE'
#!/bin/bash
set -e

read -p "Confirm running BBB rollback/maintenance? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Maintenance cancelled by user."
    exit 0
fi

DOMAIN="'$DOMAIN'"
GREENLIGHT_DIR="'$GREENLIGHT_DIR'"
EMAIL="'$EMAIL'"

echo "===== Running BBB + Greenlight Maintenance ====="

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

# ======== SETUP WEEKLY CRON FOR MAINTENANCE ========
echo "[15] Setting up weekly cron job for automatic maintenance..."
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/bbb_maintenance.sh >> /var/log/bbb_maintenance.log 2>&1") | crontab -

# ======== FINAL CHECK ========
echo "[16] Running final BBB check..."
bbb-conf --check

echo "===== Installation Complete! ====="
echo "Greenlight URL: https://$DOMAIN"
echo "Greenlight systemd service: systemctl status greenlight.service"
echo "Maintenance script runs every Sunday at 3 AM."
echo "Full log saved at $LOGFILE"
