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
RBENV_ROOT="$GREENLIGHT_DIR/.rbenv"

# ======== CLEAN OLD INSTALLATION ========
echo "[0] Cleaning old Greenlight installation (if any)..."
sudo systemctl stop greenlight || true
sudo systemctl disable greenlight || true
sudo rm -f /etc/systemd/system/greenlight.service
sudo systemctl daemon-reload
sudo rm -rf "$GREENLIGHT_DIR" || true
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

# ======== CLEAN NODE / NPM CONFLICTS ========
echo "[3] Cleaning old Node.js/npm packages..."
sudo apt remove -y nodejs npm || true
sudo apt autoremove -y

# ======== INSTALL NODE 20.x + NPM ========
echo "[4] Installing Node.js 20.x + npm from Nodesource..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# Verify installation
echo "Node.js version: $(node -v)"
echo "NPM version: $(npm -v)"

# Install Yarn globally
sudo npm install -g yarn
echo "Yarn version: $(yarn -v)"

# ======== SET HOSTNAME ========
echo "[5] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[6] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ======== INSTALL RUBY VIA PER-USER RBENV ========
echo "[7] Installing Ruby 3.1.x via per-user rbenv..."

mkdir -p "$GREENLIGHT_DIR"
cd "$GREENLIGHT_DIR"

git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
mkdir -p "$RBENV_ROOT/plugins"
git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"

# Load rbenv for current shell
export RBENV_ROOT="$RBENV_ROOT"
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
git clone https://github.com/bigbluebutton/greenlight.git "$GREENLIGHT_DIR"
cd "$GREENLIGHT_DIR"
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
ExecStart=$RBENV_ROOT/shims/bundle exec puma -C config/puma.rb
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
