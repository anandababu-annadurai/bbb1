#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ===== User Input =====
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -s -p "Enter PostgreSQL DB password for Greenlight: " DB_PASS
echo ""

# ===== Update system =====
echo "[1] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y software-properties-common curl gnupg2 wget ufw

# ===== Allow SSH =====
echo "[2] Configuring UFW firewall to allow SSH and HTTP/HTTPS..."
sudo ufw allow 22
sudo ufw allow 80
sudo ufw allow 443
sudo ufw --force enable

# ===== PostgreSQL setup =====
echo "[3] Installing PostgreSQL..."
sudo apt-get install -y postgresql postgresql-contrib
sudo systemctl enable postgresql
sudo systemctl start postgresql

# Create Greenlight DB user & database
sudo -u postgres psql -c "CREATE ROLE greenlight WITH LOGIN PASSWORD '$DB_PASS';"
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight;"

# ===== BigBlueButton repo setup for Ubuntu 20.04 =====
echo "[4] Configuring BigBlueButton repository for Focal..."
# Remove old/extraneous repos
sudo rm -f /etc/apt/sources.list.d/bbb.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-focal.list

# Add correct repo
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list

# Import GPG key
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 37B5DD5EFAB46452

# Update package lists
sudo apt-get update -y

# ===== Install BigBlueButton =====
echo "[5] Installing BigBlueButton..."
sudo apt-get install -y bigbluebutton

# ===== Enable SSL for Greenlight =====
echo "[6] Configuring SSL..."
sudo bbb-conf --setip $DOMAIN
sudo bbb-conf --enable-ssl

# ===== Post-install checks =====
echo "[7] Running BBB checks..."
sudo bbb-conf --check

echo "===== BBB + Greenlight Installation Completed Successfully ====="
