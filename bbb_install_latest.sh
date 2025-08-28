#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_greenlight_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== 🚀 BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter your email (for Let's Encrypt SSL): " EMAIL
read -p "Enter a password for PostgreSQL Greenlight DB user: " GREENLIGHT_DB_PASS

# ======== VARIABLES ========
GREENLIGHT_USER="greenlight"
GREENLIGHT_DIR="/var/www/greenlight"

# ======== SYSTEM UPDATE ========
echo "[1] Updating system..."
apt-get update -y && apt-get upgrade -y

# ======== INSTALL DEPENDENCIES ========
echo "[2] Installing dependencies..."
apt-get install -y curl wget gnupg2 git-core software-properties-common \
    libpq-dev build-essential libssl-dev libreadline-dev zlib1g-dev \
    libsqlite3-dev postgresql postgresql-contrib nginx

# ======== INSTALL NODEJS + YARN ========
echo "[3] Installing Node.js + Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
npm install -g yarn
node -v && npm -v && yarn -v

# ======== INSTALL RBENV + RUBY ========
echo "[4] Installing rbenv + Ruby..."
if [ ! -d "/usr/local/rbenv" ]; then
    git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
fi
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init - bash)"

rbenv install -s 3.1.6
rbenv global 3.1.6

gem install bundler
bundle -v

# ======== CONFIGURE POSTGRES ========
echo "[5] Configuring PostgreSQL..."
sudo -u postgres psql <<EOF
DO
\$do\$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_roles WHERE rolname = '$GREENLIGHT_USER') THEN
      CREATE ROLE $GREENLIGHT_USER LOGIN PASSWORD '$GREENLIGHT_DB_PASS';
   END IF;
END
\$do\$;
EOF

sudo -u postgres psql <<EOF
DO
\$do\$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_database WHERE datname = 'greenlight_production') THEN
      CREATE DATABASE greenlight_production OWNER $GREENLIGHT_USER;
   END IF;
END
\$do\$;
EOF

# ======== INSTALL GREENLIGHT ========
echo "[6] Installing Greenlight..."
if [ ! -d "$GREENLIGHT_DIR" ]; then
    git clone https://github.com/bigbluebutton/greenlight.git -b v3 $GREENLIGHT_DIR
fi
cd $GREENLIGHT_DIR
rbenv exec bundle install

# ======== CONFIGURE GREENLIGHT ENV ========
echo "[7] Configuring Greenlight environment..."
cat > $GREENLIGHT_DIR/.env <<EOL
SECRET_KEY_BASE=$(openssl rand -hex 64)
BIGBLUEBUTTON_ENDPOINT=https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET=$(bbb-conf --secret | grep -oP '(?<=Secret: ).*')
DATABASE_URL=postgres://$GREENLIGHT_USER:$GREENLIGHT_DB_PASS@localhost/greenlight_production
SMTP_SERVER=smtp.gmail.com
SMTP_PORT=587
SMTP_DOMAIN=$DOMAIN
SMTP_USERNAME=your-email@gmail.com
SMTP_PASSWORD=your-smtp-password
SMTP_AUTH=plain
SMTP_STARTTLS=true
EOL

chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR
chmod 600 $GREENLIGHT_DIR/.env

# ======== SYSTEMD SERVICE ========
echo "[8] Creating Greenlight systemd service..."
cat > /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight Rails App
After=network.target

[Service]
Type=simple
User=$GREENLIGHT_USER
WorkingDirectory=$GREENLIGHT_DIR
EnvironmentFile=$GREENLIGHT_DIR/.env
ExecStart=/usr/local/rbenv/shims/bundle exec puma -C config/puma.rb
Restart=always

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable greenlight
systemctl start greenlight

# ======== CONFIGURE NGINX ========
echo "[9] Configuring Nginx..."
cat > /etc/nginx/sites-available/greenlight <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root $GREENLIGHT_DIR/public;

    passenger_enabled off;
    passenger_app_env production;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOL

ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/greenlight
nginx -t && systemctl restart nginx

# ======== ENABLE HTTPS ========
echo "[10] Enabling HTTPS with Let's Encrypt..."
apt-get install -y certbot python3-certbot-nginx
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --redirect
systemctl enable certbot.timer
certbot renew --dry-run

echo "===== ✅ Greenlight is ready at: https://$DOMAIN ====="
