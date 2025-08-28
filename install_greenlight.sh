#!/bin/bash
set -e

LOG_FILE="/var/log/greenlight_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Greenlight Installation ====="

# USER INPUT
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
DOMAIN=${DOMAIN:-bbb.example.com}

read -p "Enter your email for Let's Encrypt SSL (e.g., admin@example.com): " EMAIL
EMAIL=${EMAIL:-admin@example.com}

# Create greenlight directory
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

# Configure .env
cp .env.example .env
SECRET=$(bbb-conf --secret | grep -i "Secret:" | awk '{print $2}')
API_URL="https://$DOMAIN/bigbluebutton/api"

sed -i "s|^BIGBLUEBUTTON_ENDPOINT=.*|BIGBLUEBUTTON_ENDPOINT=$API_URL|" .env
sed -i "s|^BIGBLUEBUTTON_SECRET=.*|BIGBLUEBUTTON_SECRET=$SECRET|" .env
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(bundle exec rake secret)|" .env

bundle exec rake db:setup
bundle exec rake assets:precompile

# Create systemd service
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

# Configure Nginx + SSL
apt-get install -y nginx certbot
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

# Configure UFW firewall
apt-get install -y ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow OpenSSH
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 1935/tcp
ufw allow 7443/tcp
ufw allow 3478/udp
ufw allow 5349/tcp
ufw allow 5349/udp
ufw allow 16384:32768/udp
ufw --force enable

# Enable auto SSL renewal
cat >/etc/cron.d/certbot-renew <<EOL
0 3 * * * root certbot renew --quiet && systemctl reload nginx
EOL

echo "===== Greenlight Installation Completed ====="
echo "Access Greenlight at: https://$DOMAIN"
echo "Check logs: journalctl -u greenlight -f"
