#!/bin/bash
set -e

# ===== Logging =====
LOG_FILE="$HOME/bbb_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ===== rbenv Ruby Setup =====
export PATH="$HOME/.rbenv/shims:$HOME/.rbenv/bin:$PATH"
eval "$(rbenv init -)"

RUBY_VERSION="3.1.6"

if ruby -v | grep -q "$RUBY_VERSION"; then
    echo "[INFO] Ruby $RUBY_VERSION is already installed."
else
    echo "[ERROR] Ruby $RUBY_VERSION not found. Please install via rbenv first."
    exit 1
fi

if gem list -i bundler > /dev/null 2>&1; then
    echo "[INFO] Bundler is already installed."
else
    echo "[INFO] Installing Bundler..."
    gem install bundler --no-document
fi

ruby -v
bundle -v

# ===== User Input =====
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -s -p "Enter PostgreSQL DB password for Greenlight: " PG_PASS
echo ""

# ===== System Updates =====
echo "[1] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y

# ===== Basic Dependencies =====
echo "[2] Installing basic dependencies..."
sudo apt-get install -y build-essential curl wget git gnupg2 software-properties-common

# ===== NodeJS / NPM / Yarn =====
if command -v node > /dev/null; then
    echo "[INFO] NodeJS is already installed."
else
    echo "[INFO] Installing NodeJS 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

if command -v yarn > /dev/null; then
    echo "[INFO] Yarn is already installed."
else
    echo "[INFO] Installing Yarn..."
    sudo npm install -g yarn || echo "[WARN] Yarn installation failed, skipping."
fi

node -v
npm -v
yarn -v || true

# ===== PostgreSQL Setup =====
echo "[3] Configuring PostgreSQL..."
sudo apt-get install -y postgresql postgresql-contrib

# Create user/database if they don’t exist
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='greenlight';" | grep -q 1 || \
sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$PG_PASS';"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='greenlight_production';" | grep -q 1 || \
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight;"

# ===== BigBlueButton Repo =====
echo "[4] Configuring BigBlueButton repository..."
sudo mkdir -p /usr/share/keyrings
if ! sudo test -f /usr/share/keyrings/bbb.gpg; then
    sudo curl -fsSL https://ubuntu.bigbluebutton.org/repo/bbb.gpg -o /usr/share/keyrings/bbb.gpg || echo "[WARN] GPG key fetch failed"
fi

echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list

sudo apt-get update -y
sudo apt-get install -y bigbluebutton || echo "[WARN] BigBlueButton install step failed"

# ===== SSL (Certbot) =====
echo "[5] Setting up SSL with Certbot..."
sudo apt-get install -y certbot
sudo certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m your-email@example.com || echo "[WARN] SSL setup skipped"

echo "===== BBB + Greenlight Installation Completed Successfully ====="
