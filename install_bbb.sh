#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter PostgreSQL DB password for Greenlight: " DB_PASS

GREENLIGHT_USER="greenlight"
GREENLIGHT_DB_PASS="$DB_PASS"
GREENLIGHT_DIR="/var/www/greenlight"

# ======== CHECK DEPENDENCIES ========
echo "[1] Installing basic dependencies..."
sudo apt update
sudo apt install -y curl gnupg2 build-essential git \
    libssl-dev libreadline-dev zlib1g-dev \
    postgresql postgresql-contrib nginx wget

# ======== INSTALL NODE + YARN (skip if present) ========
echo "[2] Installing Node.js + Yarn..."
if ! command -v node >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt install -y nodejs
fi

if ! command -v yarn >/dev/null 2>&1; then
    sudo npm install -g yarn
fi

node -v
npm -v
yarn -v || echo "Yarn may require fixing manually"

# ======== INSTALL RBENV + RUBY (skip if present) ========
echo "[3] Installing rbenv + Ruby 3.1.6..."
if ! command -v ruby >/dev/null 2>&1 || [[ "$(ruby -v)" != *"3.1.6"* ]]; then
    git clone https://github.com/rbenv/rbenv.git ~/.rbenv
    git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(~/.rbenv/bin/rbenv init -)"
    ~/.rbenv/bin/rbenv install -s 3.1.6
    ~/.rbenv/bin/rbenv global 3.1.6
fi

ruby -v
gem install bundler --no-document
bundle -v

# ======== CONFIGURE POSTGRESQL ========
echo "[4] Configuring PostgreSQL for Greenlight..."

# Create greenlight role if not exists
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = '$GREENLIGHT_USER'" | grep -q 1 || \
sudo -u postgres psql -c "CREATE ROLE $GREENLIGHT_USER LOGIN PASSWORD '$GREENLIGHT_DB_PASS';"

# Create greenlight database if not exists
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'greenlight_production'" | grep -q 1 || \
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER $GREENLIGHT_USER;"

# ======== INSTALL GREENLIGHT ========
echo "[5] Installing Greenlight..."
if [ ! -d "$GREENLIGHT_DIR" ]; then
    sudo git clone https://github.com/bigbluebutton/greenlight.git -b v3 $GREENLIGHT_DIR
    sudo chown -R $USER:$USER $GREENLIGHT_DIR
fi

cd $GREENLIGHT_DIR

# Configure database.yml
mkdir -p config
cat > config/database.yml <<EOL
production:
  adapter: postgresql
  encoding: unicode
  database: greenlight_production
  pool: 5
  username: $GREENLIGHT_USER
  password: $GREENLIGHT_DB_PASS
  host: localhost
EOL

bundle install
RAILS_ENV=production bundle exec rake db:setup

# ======== CONFIGURE BBB REPO ========
echo "[6] Configuring BigBlueButton repository..."
BBB_KEY=/usr/share/keyrings/bbb.gpg
sudo rm -f $BBB_KEY
curl -fsSL https://ubuntu.bigbluebutton.org/repo/bbb.gpg | sudo gpg --dearmor -o $BBB_KEY

echo "deb [signed-by=$BBB_KEY] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | \
    sudo tee /etc/apt/sources.list.d/bbb.list

sudo apt update -y

# ======== CREATE .ENV FOR GREENLIGHT ========
echo "[7] Creating Greenlight .env file..."
cat > $GREENLIGHT_DIR/.env <<EOL
RAILS_ENV=production
DATABASE_URL=postgresql://$GREENLIGHT_USER:$GREENLIGHT_DB_PASS@localhost/greenlight_production
SECRET_KEY_BASE=$(openssl rand -hex 64)
BIGBLUEBUTTON_ENDPOINT=https://$DOMAIN/bigbluebutton/api/
BIGBLUEBUTTON_SECRET=your_bbb_secret_here
DEFAULT_REGISTRATION=open
ALLOW_GREENLIGHT_ACCOUNTS=true
EOL

# ======== CONFIGURE NGINX ========
echo "[8] Configuring Nginx..."
cat > /etc/nginx/sites-available/greenlight <<EOL
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
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl restart nginx

# ======== CREATE SYSTEMD SERVICE ========
echo "[9] Creating Greenlight systemd service..."
cat > /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$GREENLIGHT_DIR
Environment=RAILS_ENV=production
ExecStart=$HOME/.rbenv/shims/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl start greenlight

echo "===== BBB + Greenlight Installation Completed ====="
echo "Access Greenlight: http://$DOMAIN"
echo "Check status: systemctl status greenlight"
