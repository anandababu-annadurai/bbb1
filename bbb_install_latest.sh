#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email for Let's Encrypt SSL (e.g., admin@example.com): " EMAIL
EMAIL=${EMAIL:-admin@example.com}

echo "Using domain: $DOMAIN"
echo "Using email: $EMAIL"

# ======== UPDATE SYSTEM ========
echo "[1] Updating system..."
apt-get update -y
apt-get upgrade -y

# ======== INSTALL DEPENDENCIES ========
echo "[2] Installing dependencies..."
apt-get install -y \
  software-properties-common \
  apt-transport-https \
  ca-certificates \
  curl wget gnupg2 \
  build-essential \
  git-core \
  nginx \
  python3-pip \
  redis-server \
  postgresql postgresql-contrib \
  libpq-dev \
  imagemagick \
  libxml2-dev libxslt1-dev \
  zlib1g-dev libssl-dev \
  libreadline-dev libyaml-dev libffi-dev libgdbm-dev libncurses5-dev libgdbm6 \
  libgmp-dev autoconf bison

# ======== NODEJS + YARN ========
echo "[3] Installing Node.js + Yarn..."
# Remove conflicting npm
apt-get remove -y npm || true

# Install Node.js via Nodesource (includes npm)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Enable corepack + Yarn
corepack enable
npm install -g yarn

node -v
npm -v
yarn -v

# ======== CREATE SWAP IF NEEDED ========
if ! swapon --show | grep -q '/swapfile'; then
    echo "[Extra] Creating 2G swapfile to prevent Ruby compile issues..."
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ======== INSTALL RBENV + RUBY ========
echo "[4] Installing rbenv + Ruby..."
if [ -d "/usr/local/rbenv" ]; then
    rm -rf /usr/local/rbenv
fi

git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
chmod -R 755 /usr/local/rbenv
chown -R root:root /usr/local/rbenv

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"

echo "Installing Ruby 3.1.6..."
rbenv install 3.1.6

echo "Installing Ruby 3.1.0 (required by Greenlight)..."
rbenv install 3.1.0

rbenv global 3.1.6
rbenv rehash
export PATH="$RBENV_ROOT/shims:$PATH"

ruby -v
gem -v

# ======== INSTALL BIGBLUEBUTTON ========
echo "[5] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/repo/bigbluebutton.asc | gpg --dearmor -o /usr/share/keyrings/bbb.gpg
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/xenial-250 bigbluebutton-xenial main" | tee /etc/apt/sources.list.d/bigbluebutton.list
apt-get update -y
apt-get install -y bigbluebutton

bbb-conf --check

# ======== CONFIGURE SSL ========
echo "[6] Setting up Let's Encrypt SSL..."
apt-get install -y certbot
certbot certonly --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL || true

# ======== INSTALL GREENLIGHT ========
echo "[7] Installing Greenlight..."
cd /var/www/
if [ -d "greenlight" ]; then
  rm -rf greenlight
fi

git clone https://github.com/bigbluebutton/greenlight.git
cd greenlight

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"

rbenv local 3.1.0
gem install bundler
bundle install
yarn install --check-files

# ======== CONFIGURE GREENLIGHT ========
echo "[8] Configuring Greenlight..."
cp .env.example .env
SECRET=$(bbb-conf --secret | grep -i "Secret:" | awk '{print $2}')
API_URL="https://$DOMAIN/bigbluebutton/api"

sed -i "s|^BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$API_URL|" .env
sed -i "s|^BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$SECRET|" .env
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(bundle exec rake secret)|" .env

bundle exec rake db:setup
bundle exec rake assets:precompile

# ======== CREATE SYSTEMD SERVICE ========
echo "[9] Creating Greenlight systemd service..."
cat >/etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight
After=network.target

[Service]
Type=simple
WorkingDirectory=/var/www/greenlight
ExecStart=/usr/local/rbenv/shims/bundle exec puma -C config/puma.rb
Restart=always
User=root
Environment=RAILS_ENV=production

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reexec
systemctl enable greenlight
systemctl restart greenlight

# ======== CONFIGURE NGINX ========
echo "[10] Configuring Nginx..."
cat >/etc/nginx/sites-available/greenlight <<EOL
server {
  listen 80;
  server_name $DOMAIN;
  return 301 https://\$host\$request_uri;
}

server {
  listen 443 ssl;
  server_name $DOMAIN;

  ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

  root /var/www/greenlight/public;

  location / {
    proxy_pass http://127.0.0.1:3000;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Ssl on;
    proxy_set_header X-Forwarded-Port 443;
    proxy_set_header X-Forwarded-Host \$host;
  }
}
EOL

ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# ======== FIREWALL (UFW) ========
echo "[11] Configuring UFW firewall..."
apt-get install -y ufw
ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# Allow SSH
ufw allow OpenSSH
ufw allow 22/tcp

# Web
ufw allow 80/tcp
ufw allow 443/tcp

# BBB services
ufw allow 1935/tcp
ufw allow 7443/tcp
ufw allow 3478/udp
ufw allow 5349/tcp
ufw allow 5349/udp
ufw allow 16384:32768/udp

ufw --force enable
ufw status verbose

# ======== AUTO SSL RENEW ========
echo "[12] Enabling auto SSL renew..."
cat >/etc/cron.d/certbot-renew <<EOL
0 3 * * * root certbot renew --quiet && systemctl reload nginx
EOL

# ======== FINAL HEALTH CHECK ========
echo "[13] Running health checks..."

if systemctl is-active --quiet nginx; then
  echo "[OK] Nginx is running."
else
  echo "[ERROR] Nginx is NOT running!"
fi

if systemctl is-active --quiet greenlight; then
  echo "[OK] Greenlight service is running."
else
  echo "[ERROR] Greenlight service is NOT running!"
fi

if [ -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem ]; then
  echo "[OK] SSL certificate installed for $DOMAIN."
else
  echo "[ERROR] SSL certificate NOT found!"
fi

BBB_CHECK=$(curl -s "http://localhost/bigbluebutton/api" | grep "<response>")
if [[ "$BBB_CHECK" == *"<response>"* ]]; then
  echo "[OK] BigBlueButton API is responding."
else
  echo "[ERROR] BBB API is NOT responding!"
fi

echo ""
echo "===== Installation Completed ====="
echo "👉 Access Greenlight at: https://$DOMAIN"
echo "👉 Logs: journalctl -u greenlight -f"
echo "👉 Firewall: ufw status verbose"
echo "👉 SSL Auto-renew: runs daily at 3AM"
