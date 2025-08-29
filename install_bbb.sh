#!/bin/bash
set -e
LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ===== USER INPUT =====
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -s -p "Enter PostgreSQL DB password for Greenlight: " PG_PASSWORD
echo
read -p "Enter your email for Let's Encrypt SSL: " EMAIL

# ===== SYSTEM UPDATE =====
echo "[INFO] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl gnupg2 build-essential software-properties-common ufw

# ===== CLEAN OLD BBB REPOSITORIES =====
echo "[INFO] Cleaning old BigBlueButton repositories..."
sudo rm -f /etc/apt/sources.list.d/bbb.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-focal.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-xenial.list

# Remove any existing BBB GPG keys
sudo rm -f /usr/share/keyrings/bbb.gpg
sudo apt-key del 37B5DD5EFAB46452 2>/dev/null || true

# ===== ADD BBB FOCAL-270 REPO (Latest) =====
echo "[INFO] Adding BigBlueButton Focal-270 repository..."
sudo mkdir -p /usr/share/keyrings

# Download and add the correct GPG key
wget -qO- https://ubuntu.bigbluebutton.org/repo/bigbluebutton.asc | sudo gpg --dearmor -o /usr/share/keyrings/bigbluebutton-keyring.gpg

# Add the repository
echo "deb [signed-by=/usr/share/keyrings/bigbluebutton-keyring.gpg] https://ubuntu.bigbluebutton.org/focal-270/ bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton.list

# Update package lists
sudo apt-get update -y

# ===== INSTALL BASIC DEPENDENCIES =====
echo "[INFO] Installing basic dependencies..."
sudo apt-get install -y git ufw wget software-properties-common curl build-essential

# ===== CHECK / INSTALL RUBY 3.1.6 via rbenv =====
if command -v ruby >/dev/null 2>&1; then
    RUBY_VERSION=$(ruby -v | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
    echo "[INFO] Ruby is already installed: $(ruby -v)"
    if [[ "$RUBY_VERSION" < "3.1.0" ]]; then
        echo "[WARNING] Ruby version is older than 3.1.x, consider upgrading"
    fi
else
    echo "[INFO] Installing Ruby 3.1.6 via rbenv..."
    # Install rbenv dependencies
    sudo apt-get install -y libssl-dev libreadline-dev zlib1g-dev autoconf bison build-essential libyaml-dev libreadline-dev libncurses5-dev libffi-dev libgdbm-dev
    
    # Install rbenv
    git clone https://github.com/rbenv/rbenv.git ~/.rbenv
    cd ~/.rbenv && src/configure && make -C src
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
    echo 'eval "$(rbenv init -)"' >> ~/.bashrc
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)"
    
    # Install ruby-build
    git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
    
    # Install Ruby 3.1.6
    ~/.rbenv/bin/rbenv install -s 3.1.6
    ~/.rbenv/bin/rbenv global 3.1.6
    export PATH="$HOME/.rbenv/shims:$PATH"
    
    # Install bundler
    gem install bundler --no-document
    echo "[INFO] Ruby 3.1.6 + Bundler installed successfully."
fi

# ===== CHECK / INSTALL NODE + NPM =====
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo "[INFO] Node & NPM already installed: $(node -v), $(npm -v)"
else
    echo "[INFO] Installing Node.js 18.x and NPM..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# ===== CHECK / INSTALL YARN =====
if command -v yarn >/dev/null 2>&1; then
    echo "[INFO] Yarn already installed: $(yarn -v)"
else
    echo "[INFO] Installing Yarn..."
    sudo npm install -g yarn
fi

# ===== CHECK / INSTALL POSTGRESQL =====
if command -v psql >/dev/null 2>&1; then
    echo "[INFO] PostgreSQL is already installed."
else
    echo "[INFO] Installing PostgreSQL..."
    sudo apt-get install -y postgresql postgresql-contrib
    sudo systemctl enable postgresql
    sudo systemctl start postgresql
fi

# ===== CONFIGURE POSTGRESQL =====
echo "[INFO] Configuring PostgreSQL..."
# Set password for postgres user
sudo -u postgres psql -c "ALTER USER postgres PASSWORD '$PG_PASSWORD';"

# Create Greenlight database if it doesn't exist
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='greenlight_production'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER postgres;"
echo "[INFO] Greenlight database configured successfully."

# ===== FIREWALL CONFIG =====
echo "[INFO] Configuring UFW firewall..."
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw allow 1935/tcp  # RTMP
sudo ufw allow 5066/tcp  # FreeSWITCH SIP
sudo ufw allow 16384:32768/udp  # RTP/SRTP
sudo ufw --force enable

# ===== INSTALL BBB =====
echo "[INFO] Installing BigBlueButton..."
wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v focal-270 -s $DOMAIN -e $EMAIL

# ===== INSTALL GREENLIGHT =====
echo "[INFO] Installing Greenlight..."
sudo apt-get install -y bigbluebutton-greenlight

# ===== CONFIGURE GREENLIGHT =====
echo "[INFO] Configuring Greenlight..."
# Generate secret key
SECRET_KEY_BASE=$(openssl rand -hex 64)

# Create Greenlight configuration
sudo tee /etc/bigbluebutton/greenlight.env > /dev/null <<EOF
SECRET_KEY_BASE=$SECRET_KEY_BASE
BIGBLUEBUTTON_ENDPOINT=https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET=$(sudo bbb-conf --secret | grep Secret: | cut -d' ' -f2)
DB_ADAPTER=postgresql
DB_HOST=localhost
DB_NAME=greenlight_production
DB_USERNAME=postgres
DB_PASSWORD=$PG_PASSWORD
RAILS_ENV=production
EOF

# Set proper permissions
sudo chown bigbluebutton:bigbluebutton /etc/bigbluebutton/greenlight.env
sudo chmod 600 /etc/bigbluebutton/greenlight.env

# ===== RESTART SERVICES =====
echo "[INFO] Restarting services..."
sudo systemctl restart nginx
sudo systemctl restart bigbluebutton-greenlight

# ===== FINAL CONFIGURATION =====
echo "[INFO] Running final BigBlueButton configuration..."
sudo bbb-conf --check

echo "===== BBB + Greenlight Installation Completed Successfully ====="
echo ""
echo "=== IMPORTANT INFORMATION ==="
echo "Domain: $DOMAIN"
echo "Greenlight URL: https://$DOMAIN"
echo "BBB Admin: https://$DOMAIN/admin"
echo ""
echo "To get BBB secret: sudo bbb-conf --secret"
echo "To check status: sudo bbb-conf --check"
echo "Logs: tail -f $LOG_FILE"
echo ""
echo "Please wait a few minutes for all services to fully start."
