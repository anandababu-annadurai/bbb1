#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -sp "Enter PostgreSQL DB password for Greenlight: " PG_PASS
echo

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y software-properties-common curl ufw

# ======== CLEAN OLD BBB REPOS ========
echo "[2] Cleaning old BBB repos..."
sudo rm -f /etc/apt/sources.list.d/bbb.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-xenial.list

echo "[3] Adding BBB Focal repo..."
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list
curl -fsSL https://ubuntu.bigbluebutton.org/repo/bbb.gpg | sudo tee /usr/share/keyrings/bbb.gpg > /dev/null

sudo apt-get update -y

# ======== INSTALL BBB DEPENDENCIES ========
echo "[4] Installing basic dependencies..."
sudo apt-get install -y bbb-html5 bbb-record-core bbb-web bbb-greenlight nginx certbot python3-certbot-nginx ufw

# ======== SETUP POSTGRESQL ========
echo "[5] Configuring PostgreSQL..."
sudo apt-get install -y postgresql postgresql-contrib
sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$PG_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight;" || true

# ======== CONFIGURE SSL ========
echo "[6] Configuring SSL with Let's Encrypt..."
sudo ufw allow 'OpenSSH'
sudo ufw allow 'Nginx Full'
sudo ufw enable -y
sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN"

# ======== FINALIZE BBB ========
echo "[7] Enabling BBB services..."
sudo systemctl enable bbb-web bbb-html5 bbb-record-core
sudo systemctl restart bbb-web bbb-html5 bbb-record-core

echo "===== BBB + Greenlight Installation Completed Successfully ====="
echo "Browse your BBB site at https://$DOMAIN"
