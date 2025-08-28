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

# ======== UPDATE SYSTEM ========
echo "[1] Updating system packages..."
apt-get update -y
apt-get upgrade -y

# ======== INSTALL DEPENDENCIES ========
echo "[2] Installing dependencies..."
apt-get install -y curl gnupg build-essential git \
  libssl-dev libreadline-dev zlib1g-dev \
  libpq-dev postgresql postgresql-contrib \
  nginx

# ======== INSTALL NODEJS + YARN ========
echo "[3] Installing Node.js + Yarn..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs
corepack enable
npm install -g yarn

node -v
npm -v
yarn -v

# ======== INSTALL RBENV + RUBY ========
echo "[4] Installing rbenv + Ruby..."
if [ ! -d "/usr/local/rbenv" ]; then
    git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
    git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
fi

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"
eval "$(rbenv init - bash)"

if ! rbenv versions | grep -q "3.1.6"; then
    rbenv install 3.1.6
fi
rbenv global 3.1.6

gem install bundler
bundle -v

# ======== CONFIGURE POSTGRES ========
echo "[5] Configuring PostgreSQL..."
cd /tmp
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
    useradd -m -s /bin/bash $GREENLIGHT_USER || true
    chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR
fi

cd $GREENLIGHT_DIR

# Configure database.yml
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

# Install gems as greenlight user
sudo -u $GREENLIGHT_USER -H bash -c "
  export RBENV_ROOT=/usr/local/rbenv
  export PATH=\$RBENV_ROOT/bin:\$PATH
  eval \$(rbenv init - bash)
  cd $GREENLIGHT_DIR
  bundle install --deployment --without development test
  RAILS_ENV=production bundle exec rake db:setup
"

echo "===== Installation Completed Successfully ====="
