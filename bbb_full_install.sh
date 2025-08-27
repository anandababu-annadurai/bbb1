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

# ======== FIREWALL SETUP (EARLY) - ENSURE SSH IS ALWAYS ALLOWED ========
echo "[0] Configuring firewall with SSH protection..."
# Reset UFW to ensure clean state
sudo ufw --force reset
# CRITICAL: Allow SSH FIRST before enabling firewall
sudo ufw allow ssh
sudo ufw allow 22/tcp
echo "SSH access secured before proceeding..."

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential \
    zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev \
    libpq-dev postgresql postgresql-contrib nginx unzip zip

# ======== REMOVE OLD BRIGHTBOX PPA ========
if [ -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list ]; then
    echo "[2] Removing old Brightbox Ruby PPA..."
    sudo rm /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list
fi
sudo apt update

# ======== SET HOSTNAME ========
echo "[3] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
if ! grep -q "$DOMAIN" /etc/hosts; then
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
fi

# ======== INSTALL BIGBLUEBUTTON ========
echo "[4] Installing BigBlueButton via official script..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g

# ======== INSTALL NODE 20 & YARN ========
echo "[5] Installing Node.js 20.x and Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
npm -v
yarn -v || sudo npm install -g yarn

# ======== INSTALL RBENV + RUBY 3.3.6 ========
echo "[6] Installing rbenv and Ruby 3.3.6..."
if [ ! -d "/usr/local/rbenv" ]; then
    sudo git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    cd /usr/local/rbenv && sudo src/configure && sudo make -C src
    sudo mkdir -p /usr/local/rbenv/plugins
    sudo git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
fi

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"

rbenv install -s 3.3.6
rbenv global 3.3.6

gem update --system
gem install bundler

# ======== INSTALL GREENLIGHT ========
echo "[7] Installing Greenlight..."
sudo mkdir -p /var/www
cd /var/www
if [ ! -d greenlight ]; then
    sudo git clone https://github.com/bigbluebutton/greenlight.git
fi
cd greenlight
rbenv local 3.3.6
gem install bundler
bundle install
yarn install || echo "[WARN] Yarn install warning ignored"

# ======== CONFIGURE POSTGRESQL ========
echo "[8] Configuring PostgreSQL database..."
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='greenlight'" | grep -q 1 || sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$GREENLIGHT_DB_PASS';"
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='greenlight_development'" | grep -q 1 || sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE greenlight_development TO greenlight;"

# Create database.yml configuration file
echo "[8.1] Creating database configuration..."
cat > config/database.yml <<EOL
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  username: greenlight
  password: $GREENLIGHT_DB_PASS
  host: localhost

development:
  <<: *default
  database: greenlight_development

production:
  <<: *default
  database: greenlight_production
EOL

# Set proper environment and run database setup
export RAILS_ENV=development
bundle exec rake db:create db:migrate db:seed || echo "[WARN] DB setup warning ignored"

# ======== GREENLIGHT CONFIG ========
echo "[9] Generating Greenlight secrets..."
SECRET_KEY=$(bundle exec rake secret || echo "fallback_secret")
BBB_SECRET=$(bbb-conf --secret | grep -oP '(?<=Secret: ).*' || echo "fallback_bbb_secret")

cat > config/application.yml <<EOL
SECRET_KEY_BASE: $SECRET_KEY
BIGBLUEBUTTON_ENDPOINT: https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET: $BBB_SECRET
EOL

# ======== COMPLETE FIREWALL CONFIGURATION ========
echo "[10] Completing firewall configuration (SSH already secured)..."
# Add all required ports for BBB
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw allow 3478/tcp  # STUN
sudo ufw allow 5222:5223/tcp # TCP for BBB
sudo ufw allow 16384:32768/udp # UDP for WebRTC

# Double-check SSH is allowed before enabling
sudo ufw status | grep -q "22/tcp" || sudo ufw allow 22/tcp
sudo ufw status | grep -q "22 " || sudo ufw allow ssh

# Enable firewall
sudo ufw --force enable

# Verify SSH is still accessible
echo "Verifying SSH access is maintained..."
sudo ufw status | grep -E "(22|ssh)" || echo "WARNING: SSH rules may not be active!"

# ======== SSH SERVICE HARDENING (Optional but recommended) ========
echo "[10.1] Ensuring SSH service is running and enabled..."
sudo systemctl enable ssh
sudo systemctl start ssh
sudo systemctl status ssh --no-pager -l

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
ExecStart=$RBENV_ROOT/shims/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

sudo systemctl daemon-reload
sudo systemctl enable greenlight.service
sudo systemctl start greenlight.service

# ======== SSL WITH CERTBOT ========
echo "[13] Installing Certbot and enabling SSL..."
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL

# ======== AUTOMATIC MAINTENANCE SCRIPT ========
echo "[14] Creating automatic maintenance script..."
cat > /usr/local/bin/bbb_maintenance.sh <<MAINTENANCE
#!/bin/bash
set -e

DOMAIN="$DOMAIN"
GREENLIGHT_DIR="$GREENLIGHT_DIR"
EMAIL="$EMAIL"

echo "===== Running BBB + Greenlight Maintenance ====="

# Ensure SSH is always allowed during maintenance
sudo ufw allow ssh
sudo ufw allow 22/tcp

sudo apt update && sudo apt upgrade -y
sudo apt install --only-upgrade -y bigbluebutton libpq-dev

if [ -d "\$GREENLIGHT_DIR" ]; then
    cd "\$GREENLIGHT_DIR"
    git pull origin main
    gem install bundler
    bundle install
    yarn install
    bundle exec rake db:migrate || echo "[WARN] DB migration warning ignored"
    sudo systemctl restart greenlight.service
fi

sudo certbot renew --quiet
sudo systemctl reload nginx

bbb-conf --check

# Verify SSH is still accessible after maintenance
sudo systemctl status ssh --no-pager -l
echo "SSH service status checked - maintenance complete"
MAINTENANCE

sudo chmod +x /usr/local/bin/bbb_maintenance.sh

# ======== SETUP WEEKLY CRON FOR MAINTENANCE ========
echo "[15] Setting up weekly cron job for automatic maintenance..."
(crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/bbb_maintenance.sh >> /var/log/bbb_maintenance.log 2>&1") | crontab -

# ======== SSH CONNECTION TEST ========
echo "[15.1] Testing SSH connectivity..."
SSH_PORT=$(sudo ss -tlnp | grep :22 | head -1 || echo "SSH port check failed")
echo "SSH service listening on: $SSH_PORT"

# ======== FINAL CHECK ========
echo "[16] Running final BBB check..."
bbb-conf --check || echo "[WARN] BBB check warning ignored"

# ======== FINAL SSH STATUS REPORT ========
echo "===== SSH Security Status ====="
echo "SSH service status:"
sudo systemctl is-active ssh
echo "UFW rules for SSH:"
sudo ufw status | grep -E "(22|ssh)"
echo "SSH listening ports:"
sudo ss -tlnp | grep :22

echo "===== Installation Complete! ====="
echo "Greenlight URL: https://$DOMAIN"
echo "SSH Status: $(sudo systemctl is-active ssh)"
echo "Greenlight Service: systemctl status greenlight.service"
echo "Maintenance script runs every Sunday at 3 AM."
echo "Logs are available at $LOG_FILE"
echo ""
echo "IMPORTANT: Verify you can SSH to this server before logging out!"
echo "UFW Firewall Status:"
sudo ufw status numbered
