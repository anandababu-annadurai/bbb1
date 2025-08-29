#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ===== USER INPUT =====
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -s -p "Enter PostgreSQL DB password for Greenlight: " PG_PASSWORD
echo

# ===== SYSTEM UPDATE =====
echo "[INFO] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y curl gnupg2 build-essential software-properties-common ufw

# ===== REMOVE OLD BBB REPO =====
sudo rm -f /etc/apt/sources.list.d/bbb.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-focal.list

# ===== ADD BBB FOCAL-260 REPO =====
echo "[INFO] Adding BigBlueButton Focal repo..."
sudo mkdir -p /usr/share/keyrings
curl -fsSL https://ubuntu.bigbluebutton.org/focal-260/bbb.gpg | sudo tee /usr/share/keyrings/bbb.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list
sudo apt-get update -y

# ===== INSTALL BASIC DEPENDENCIES =====
echo "[INFO] Installing basic dependencies..."
sudo apt-get install -y git ufw wget software-properties-common curl build-essential

# ===== CHECK / INSTALL RUBY 3.1.6 via rbenv =====
if command -v ruby >/dev/null 2>&1; then
    echo "[INFO] Ruby is already installed: $(ruby -v)"
else
    echo "[INFO] Installing Ruby 3.1.6 via rbenv..."
    git clone https://github.com/rbenv/rbenv.git ~/.rbenv
    cd ~/.rbenv && src/configure && make -C src
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
    echo 'eval "$(rbenv init -)"' >> ~/.bashrc
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init -)"
    git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
    ~/.rbenv/bin/rbenv install -s 3.1.6
    ~/.rbenv/bin/rbenv global 3.1.6
    export PATH="$HOME/.rbenv/shims:$PATH"
    gem install bundler --no-document
    echo "[INFO] Ruby 3.1.6 + Bundler installed successfully."
fi

# ===== CHECK / INSTALL NODE + NPM =====
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo "[INFO] Node & NPM already installed: $(node -v), $(npm -v)"
else
    echo "[INFO] Installing Node.js 20.x and NPM..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# ===== CHECK / INSTALL YARN =====
if command -v yarn >/dev/null 2>&1; then
    echo "[INFO] Yarn already installed: $(yarn -v)"
else
    echo "[INFO] Installing Yarn..."
    npm install -g yarn
fi

# ===== CHECK / INSTALL POSTGRESQL =====
if command -v psql >/dev/null 2>&1; then
    echo "[INFO] PostgreSQL is already installed."
else
    echo "[INFO] Installing PostgreSQL..."
    sudo apt-get install -y postgresql postgresql-contrib
fi

# ===== CREATE GREENLIGHT DB SAFELY =====
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='greenlight_production'" | grep -q 1 || \
    sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER postgres;"
echo "[INFO] Greenlight database checked/created successfully."

# ===== FIREWALL CONFIG =====
echo "[INFO] Configuring UFW firewall..."
sudo ufw allow 22    # SSH
sudo ufw allow 80    # HTTP
sudo ufw allow 443   # HTTPS
sudo ufw --force enable

# ===== INSTALL BBB + GREENLIGHT =====
echo "[INFO] Installing BigBlueButton and Greenlight..."
sudo apt-get install -y bigbluebutton-greenlight

# ===== SSL (Let's Encrypt) =====
echo "[INFO] Configuring SSL..."
sudo apt-get install -y certbot
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m your-email@example.com

echo "===== BBB + Greenlight Installation Completed Successfully ====="
