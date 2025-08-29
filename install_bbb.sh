#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Installation Started ====="

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter PostgreSQL DB password for Greenlight: " PG_PASS

# ======== REMOVE OLD BBB REPOS ========
echo "[INFO] Removing old BBB repo entries..."
sudo rm -f /etc/apt/sources.list.d/bbb.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-xenial.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-focal.list

# ======== ADD BBB FOCAL REPO ========
echo "[INFO] Adding BigBlueButton Focal repo..."
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list

# ======== IMPORT BBB GPG KEY ========
echo "[INFO] Importing BBB GPG key..."
curl -fsSL https://ubuntu.bigbluebutton.org/repo/bbb.gpg | sudo tee /usr/share/keyrings/bbb.gpg > /dev/null

# ======== UPDATE SYSTEM PACKAGES ========
echo "[INFO] Updating system packages..."
sudo apt-get update -y
sudo apt-get upgrade -y

# ======== INSTALL BASIC DEPENDENCIES ========
echo "[INFO] Installing basic dependencies..."
sudo apt-get install -y build-essential wget curl gnupg2 software-properties-common ufw

# ======== OPEN SSH (22) & ENABLE FIREWALL ========
echo "[INFO] Configuring firewall (allow SSH 22 & HTTP/HTTPS)..."
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# ======== INSTALL BIGBLUEBUTTON ========
echo "[INFO] Installing BigBlueButton core packages..."
sudo apt-get install -y bbb-html5 bbb-record-core bbb-web

# ======== INSTALL GREENLIGHT ========
echo "[INFO] Installing Greenlight..."
sudo apt-get install -y bbb-greenlight

# ======== CONFIGURE POSTGRESQL FOR GREENLIGHT ========
echo "[INFO] Configuring PostgreSQL..."
sudo -u postgres psql -c "CREATE ROLE greenlight LOGIN ENCRYPTED PASSWORD '$PG_PASS';" || true
sudo -u postgres psql -c "CREATE DATABASE greenlight_production OWNER greenlight;" || true

# ======== CONFIGURE GREENLIGHT ========
echo "[INFO] Configuring Greenlight for domain $DOMAIN..."
sudo bbb-conf --setip $DOMAIN

# ======== ENABLE SSL ========
echo "[INFO] Enabling SSL via LetsEncrypt..."
sudo bbb-conf --enable-ssl --email your-email@example.com

echo "===== BBB + Greenlight Installation Completed Successfully ====="
echo "Visit: https://$DOMAIN"
