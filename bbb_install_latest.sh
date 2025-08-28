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

# Clean install of rbenv
if [ -d "/usr/local/rbenv" ]; then
    rm -rf /usr/local/rbenv
fi

git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build

# Set proper permissions
chmod -R 755 /usr/local/rbenv
chown -R root:root /usr/local/rbenv

# Set up rbenv environment
export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"

# Install both Ruby versions (3.1.6 for system, 3.1.0 for Greenlight)
echo "Installing Ruby 3.1.6..."
rbenv install 3.1.6

echo "Installing Ruby 3.1.0 (required by Greenlight)..."
rbenv install 3.1.0

# Set global version and rehash to update shims
rbenv global 3.1.6
rbenv rehash

# Update PATH to include rbenv shims
export PATH="$RBENV_ROOT/shims:$PATH"

# Verify ruby and gem are available
which ruby
which gem
ruby -v

# Install bundler for current Ruby version (3.1.6)
gem install bundler
rbenv rehash

# Install bundler for Ruby 3.1.0 as well
echo "Installing bundler for Ruby 3.1.0..."
RBENV_VERSION=3.1.0 gem install bundler
rbenv rehash

# Verify bundle is working
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

# Create greenlight user first
useradd -m -s /bin/bash $GREENLIGHT_USER 2>/dev/null || true

# Remove existing directory if it exists but is incomplete
if [ -d "$GREENLIGHT_DIR" ] && [ ! -f "$GREENLIGHT_DIR/Gemfile" ]; then
    echo "Removing incomplete Greenlight directory..."
    rm -rf $GREENLIGHT_DIR
fi

# Clone Greenlight if directory doesn't exist
if [ ! -d "$GREENLIGHT_DIR" ]; then
    echo "Cloning Greenlight repository..."
    git clone https://github.com/bigbluebutton/greenlight.git -b v3 $GREENLIGHT_DIR
    
    # Verify clone was successful
    if [ ! -f "$GREENLIGHT_DIR/Gemfile" ]; then
        echo "Error: Greenlight clone failed or Gemfile not found!"
        echo "Directory contents:"
        ls -la $GREENLIGHT_DIR/
        exit 1
    fi
    
    chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR
fi

cd $GREENLIGHT_DIR

# Verify we're in the right directory with Gemfile
if [ ! -f "Gemfile" ]; then
    echo "Error: No Gemfile found in $GREENLIGHT_DIR"
    echo "Current directory: $(pwd)"
    echo "Directory contents:"
    ls -la
    exit 1
fi

echo "Found Gemfile, proceeding with installation..."

# Ensure config folder exists
mkdir -p config

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

# Set proper ownership
chown -R $GREENLIGHT_USER:$GREENLIGHT_USER $GREENLIGHT_DIR

# Create a robust setup script that doesn't use rbenv init
cat > /tmp/greenlight_setup.sh <<'EOL'
#!/bin/bash
set -e

echo "=== Starting Greenlight Setup ==="

# Set up rbenv environment without using eval
export RBENV_ROOT=/usr/local/rbenv
export PATH=$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH

cd /var/www/greenlight

echo "Current directory: $(pwd)"
echo "Ruby version file content: $(cat .ruby-version 2>/dev/null || echo 'No .ruby-version file')"

# Check Ruby version required by Greenlight
REQUIRED_RUBY=$(cat .ruby-version 2>/dev/null || echo "3.1.0")
echo "Required Ruby version: $REQUIRED_RUBY"

# Use direct path to the required Ruby version
RUBY_BIN_PATH="/usr/local/rbenv/versions/$REQUIRED_RUBY/bin"
RUBY_SHIM_PATH="/usr/local/rbenv/shims"

if [ -d "$RUBY_BIN_PATH" ]; then
    echo "Using Ruby $REQUIRED_RUBY directly from $RUBY_BIN_PATH"
    export PATH="$RUBY_BIN_PATH:$PATH"
    ruby -v
    
    # Install bundler if not present
    if ! command -v bundle >/dev/null 2>&1; then
        echo "Installing bundler..."
        gem install bundler
    fi
    
elif [ -x "$RUBY_SHIM_PATH/ruby" ]; then
    echo "Using Ruby via rbenv shims"
    export PATH="$RUBY_SHIM_PATH:$PATH"
    ruby -v
    
    # Install bundler via shims if not present
    if ! command -v bundle >/dev/null 2>&1; then
        echo "Installing bundler..."
        gem install bundler
        /usr/local/rbenv/bin/rbenv rehash
    fi
    
else
    echo "ERROR: Cannot find Ruby installation"
    exit 1
fi

echo "Ruby version: $(ruby -v)"
echo "Bundle version: $(bundle -v)"

# Configure bundle
echo "Configuring bundle..."
bundle config set frozen false
bundle config set deployment false

# Remove any problematic bundle state
rm -rf .bundle/ 2>/dev/null || true
rm -f Gemfile.lock 2>/dev/null || true

# Generate new Gemfile.lock with current Ruby version
echo "Generating Gemfile.lock..."
bundle install

# Now set production configuration
bundle config set deployment true
bundle config set without 'development test'

# Install gems
echo "Installing gems (this may take several minutes)..."
bundle install --verbose

# Setup database
echo "Setting up database..."
RAILS_ENV=production bundle exec rake db:setup

echo "=== Greenlight setup completed successfully ==="
EOL

chmod +x /tmp/greenlight_setup.sh

echo "Running Greenlight setup as user: $GREENLIGHT_USER"
# Run the setup script as greenlight user
sudo -u $GREENLIGHT_USER -H bash /tmp/greenlight_setup.sh

# Clean up
rm -f /tmp/greenlight_setup.sh

# ======== CONFIGURE ENVIRONMENT FILE ========
echo "[7] Creating Greenlight environment file..."
cd $GREENLIGHT_DIR

# Create basic .env file
cat > .env <<EOL
# Greenlight Configuration
RAILS_ENV=production
DATABASE_URL=postgresql://$GREENLIGHT_USER:$GREENLIGHT_DB_PASS@localhost/greenlight_production

# Generate these with: bundle exec rake secret
SECRET_KEY_BASE=$(openssl rand -hex 64)

# BigBlueButton configuration (update these with your BBB server details)
BIGBLUEBUTTON_ENDPOINT=https://$DOMAIN/bigbluebutton/api/
BIGBLUEBUTTON_SECRET=your_bbb_secret_here

# Application settings
DEFAULT_REGISTRATION=open
ALLOW_GREENLIGHT_ACCOUNTS=true
EOL

chown $GREENLIGHT_USER:$GREENLIGHT_USER .env

echo "[8] Setting up Nginx configuration..."
# Create Nginx site configuration
cat > /etc/nginx/sites-available/greenlight <<EOL
server {
    listen 80;
    server_name $DOMAIN;
    root /var/www/greenlight/public;

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

# Enable the site
ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test nginx configuration
nginx -t

# Create systemd service for Greenlight
echo "[9] Creating Greenlight systemd service..."
cat > /etc/systemd/system/greenlight.service <<EOL
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
Environment=RBENV_ROOT=/usr/local/rbenv
Environment=PATH=/usr/local/rbenv/bin:/usr/local/rbenv/shims:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/rbenv/shims/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and start services
systemctl daemon-reload
systemctl enable greenlight
systemctl start greenlight
systemctl restart nginx

echo "===== Installation Completed Successfully ====="
echo ""
echo "Next steps:"
echo "1. Configure your BigBlueButton server details in $GREENLIGHT_DIR/.env"
echo "2. Get your BBB secret with: bbb-conf --secret"
echo "3. Update BIGBLUEBUTTON_SECRET in the .env file"
echo "4. Restart Greenlight: systemctl restart greenlight"
echo "5. Access Greenlight at: http://$DOMAIN"
echo ""
echo "To check Greenlight status: systemctl status greenlight"
echo "To view logs: journalctl -u greenlight -f"
