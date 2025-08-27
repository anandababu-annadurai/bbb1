#!/bin/bash
set -e

DOMAIN=""
CLEAN=false

# ===============================
# Parse Args
# ===============================
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --clean) CLEAN=true ;;
    --domain) DOMAIN="$2"; shift ;;
  esac
  shift
done

if [[ -z "$DOMAIN" ]]; then
  echo "❌ ERROR: You must provide a domain with --domain"
  echo "Usage: sudo bash $0 --domain example.com [--clean]"
  exit 1
fi

# ===============================
# Cleanup if requested
# ===============================
if $CLEAN; then
  echo "[CLEAN] Stopping existing Greenlight service..."
  systemctl stop greenlight || true
  systemctl disable greenlight || true
  rm -f /etc/systemd/system/greenlight.service
  systemctl daemon-reload

  echo "[CLEAN] Removing old Greenlight directory..."
  rm -rf /var/www/greenlight

  echo "[CLEAN] Dropping old PostgreSQL DB/user..."
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_production;" || true
  sudo -u postgres psql -c "DROP USER IF EXISTS greenlight_user;" || true

  echo "[CLEAN] Flushing Redis cache..."
  systemctl stop redis || true
  rm -rf /var/lib/redis/* || true
  systemctl start redis || true

  echo "[CLEAN] Removing old rbenv installation..."
  rm -rf /usr/local/rbenv || true

  echo "[CLEAN] Old installation removed. Continuing with fresh install..."
fi

# ===============================
# [1] Install Dependencies
# ===============================
echo "[1] Installing dependencies..."
apt-get update -y
apt-get install -y git curl gnupg build-essential libssl-dev libreadline-dev zlib1g-dev \
                   postgresql postgresql-contrib redis-server yarn nodejs nginx \
                   certbot python3-certbot-nginx

# ===============================
# [2] Setup rbenv & Ruby
# ===============================
echo "[2] Installing rbenv and Ruby..."
git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
cd /usr/local/rbenv && src/configure && make -C src
mkdir -p /usr/local/rbenv/plugins
git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init -)"

RUBY_VERSION=3.1.4
rbenv install -s $RUBY_VERSION
rbenv global $RUBY_VERSION

gem install bundler

# ===============================
# [3] Setup Database
# ===============================
echo "[3] Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE USER greenlight_user WITH PASSWORD 'greenlight_pass';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight_user;" || true

# ===============================
# [4] Install Greenlight
# ===============================
echo "[4] Installing Greenlight..."
mkdir -p /var/www
cd /var/www
git clone https://github.com/bigbluebutton/greenlight.git
cd greenlight
git checkout v3

cp config/database.yml.example config/database.yml
sed -i 's/username:.*/username: greenlight_user/' config/database.yml
sed -i 's/password:.*/password: greenlight_pass/' config/database.yml

bundle install
yarn install || echo "[WARN] Yarn install warning ignored"

# ===============================
# [5] Setup Puma
# ===============================
echo "[5] Installing Puma..."
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

# ===============================
# [6] Precompile Assets & Setup DB
# ===============================
echo "[6] Precompiling assets and setting up DB..."
export RAILS_ENV=production
bundle exec rake assets:precompile
bundle exec rake db:create db:migrate db:seed

# ===============================
# [7] Setup Systemd Service
# ===============================
echo "[7] Creating systemd service..."
cat > /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight Puma Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/www/greenlight
Environment=RAILS_ENV=production
ExecStart=/usr/local/rbenv/shims/bundle exec puma -C config/puma.rb
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable greenlight
systemctl start greenlight

# ===============================
# [8] Nginx + SSL
# ===============================
echo "[8] Configuring Nginx for $DOMAIN..."
cat > /etc/nginx/sites-available/greenlight <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root /var/www/greenlight/public;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/greenlight
nginx -t && systemctl restart nginx

# Issue SSL certificate
echo "[9] Requesting SSL certificate for $DOMAIN..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN

echo "✅ Greenlight installed and secured with HTTPS at https://$DOMAIN"
