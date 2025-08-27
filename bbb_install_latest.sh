#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT WITH DEFAULTS ========
read -p "Enter your domain name (e.g., bbb.example.com) [bbb.example.com]: " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email address (for Let's Encrypt SSL) [admin@$DOMAIN]: " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

read -sp "Enter password for Greenlight DB user [default: greenlightpass]: " GREENLIGHT_DB_PASS
GREENLIGHT_DB_PASS=${GREENLIGHT_DB_PASS:-greenlightpass}
echo

GREENLIGHT_DIR="/var/www/greenlight"

# ======== CLEAN OLD INSTALLATION ========
echo "[0] Cleaning old Greenlight installation (if any)..."
sudo systemctl stop greenlight || true
sudo systemctl disable greenlight || true
sudo rm -f /etc/systemd/system/greenlight.service
sudo systemctl daemon-reload
sudo rm -rf "$GREENLIGHT_DIR" /usr/local/rbenv || true
cd /tmp
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_production;" || true
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_development;" || true
sudo -u postgres psql -c "DROP USER IF EXISTS greenlight_user;" || true
sudo pkill -f greenlight || echo "No greenlight processes found"

# ======== FIREWALL SETUP ========
echo "[1] Configuring firewall with SSH protection..."
sudo ufw --force reset
sudo ufw allow ssh
sudo ufw allow 22/tcp
sudo ufw --force enable

# ======== SYSTEM UPDATE ========
echo "[2] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip

# ======== REMOVE OLD RUBY PPA ========
if [ -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list ]; then
    echo "[3] Removing old Brightbox Ruby PPA..."
    sudo rm /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list
fi
sudo apt update

# ======== SET HOSTNAME ========
echo "[4] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[5] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ======== INSTALL NODE & YARN ========
echo "[6] Installing Node.js 20.x and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
npm -v
sudo npm install -g yarn
yarn -v

# ======== INSTALL RUBY VIA rbenv ========
echo "[7] Installing Ruby 3.1.x via rbenv..."
git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
cd /usr/local/rbenv && src/configure && make -C src
mkdir -p /usr/local/rbenv/plugins
git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

RUBY_VERSION=3.1.6
rbenv install -s $RUBY_VERSION
rbenv global $RUBY_VERSION
gem install bundler

# ======== CONFIGURE DATABASE ========
echo "[8] Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE USER greenlight_user WITH PASSWORD '$GREENLIGHT_DB_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight_user;" || true

# ======== INSTALL GREENLIGHT ========
echo "[9] Installing Greenlight..."
mkdir -p /var/www
cd /var/www
git clone https://github.com/bigbluebutton/greenlight.git
cd greenlight
git checkout v3

cp config/database.yml.example config/database.yml
sed -i "s/username:.*/username: greenlight_user/" config/database.yml
sed -i "s/password:.*/password: $GREENLIGHT_DB_PASS/" config/database.yml

bundle install
yarn install || echo "[WARN] Yarn install warning ignored"

# ======== SETUP PUMA ========
echo "[10] Configuring Puma..."
gem install puma

cat > config/puma.rb <<EOL
max_threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
min_threads_count = ENV.fetch("RAILS_MIN_THREADS") { max_threads_count }
threads min_threads_count, max_threads_count
port        ENV.fetch("PORT") { 3000 }
environment ENV.fetch("RAILS_ENV") { "production" }
pidfile ENV.fetch("PIDFILE") { "tmp/pids/server.pid" }
workers ENV.fetch("WEB_CONCURRENCY") { 2 }
preload_app!
plugin :tmp_restart
EOL

# ======== DB MIGRATIONS & SEED ========
echo "[11] Running DB migrations..."
export RAILS_ENV=production
bundle exec rake assets:precompile
bundle exec rake db:create db:migrate db:seed

# ======== SYSTEMD SERVICE ========
echo "[12] Creating Greenlight systemd service..."
cat > /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight Puma Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$GREENLIGHT_DIR
Environment=RAILS_ENV=production
ExecStart=/usr/local/rbenv/shims/bundle exec puma -C config/puma.rb
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl start greenlight

# ======== NGINX + SSL ========
echo "[13] Configuring Nginx for $DOMAIN..."
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
    }
}
EOL

sudo ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/greenlight
sudo nginx -t && sudo systemctl restart nginx

echo "[14] Requesting SSL certificate..."
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

echo "✅ Installation complete! Access Greenlight at: https://$DOMAIN"
