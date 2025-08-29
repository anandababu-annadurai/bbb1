#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_greenlight_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter PostgreSQL DB password for Greenlight: " DB_PASS

GREENLIGHT_USER="greenlight"
GREENLIGHT_DB_PASS="$DB_PASS"
GREENLIGHT_DIR="/var/www/greenlight"

# ======== CONFIGURE POSTGRES ========
echo "[1] Configuring PostgreSQL..."
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

# ======== CONFIGURE BBB REPO ========
echo "[2] Configuring BigBlueButton repository..."
UBUNTU_CODENAME=$(lsb_release -cs)

# Remove old repo if exists
sudo rm -f /etc/apt/sources.list.d/bbb.list

# Add repo for focal
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bbb.list

# Import GPG key
sudo rm -f /usr/share/keyrings/bbb.gpg
wget -qO- https://ubuntu.bigbluebutton.org/repo/bbb.gpg | sudo gpg --dearmor -o /usr/share/keyrings/bbb.gpg

sudo apt update

# ======== INSTALL BIGBLUEBUTTON ========
echo "[3] Installing BigBlueButton..."
sudo apt install -y bigbluebutton

# ======== INSTALL GREENLIGHT ========
echo "[4] Installing Greenlight..."
sudo useradd -m -s /bin/bash $GREENLIGHT_USER 2>/dev/null || true

if [ ! -d "$GREENLIGHT_DIR" ]; then
    sudo git clone https://github.com/bigbluebutton/greenlight.git -b v3 $GREENLIGHT_DIR
    sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR
fi

cd $GREENLIGHT_DIR

sudo -u $GREENLIGHT_USER mkdir -p config
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

sudo chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR

# Install gems and setup database
sudo -u $GREENLIGHT_USER bash -c "
export RBENV_ROOT=\$HOME/.rbenv
export PATH=\$RBENV_ROOT/bin:\$RBENV_ROOT/shims:\$PATH
cd $GREENLIGHT_DIR
bundle install
RAILS_ENV=production bundle exec rake db:setup
"

# ======== CONFIGURE NGINX ========
echo "[5] Configuring Nginx..."
sudo tee /etc/nginx/sites-available/greenlight > /dev/null <<EOL
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

# ======== CREATE GREENLIGHT SYSTEMD SERVICE ========
echo "[6] Creating Greenlight systemd service..."
sudo tee /etc/systemd/system/greenlight.service > /dev/null <<EOL
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
Environment=RBENV_ROOT=$HOME/.rbenv
Environment=PATH=$HOME/.rbenv/bin:$HOME/.rbenv/shims:/usr/local/bin:/usr/bin:/bin
ExecStart=$HOME/.rbenv/shims/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight
sudo systemctl start greenlight

echo "===== Installation Completed Successfully ====="
echo "Access Greenlight at http://$DOMAIN"
echo "Check Greenlight status: systemctl status greenlight"
echo "View logs: journalctl -u greenlight -f"
