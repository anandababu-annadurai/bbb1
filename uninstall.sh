#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_greenlight_uninstall.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BBB + Greenlight Uninstall Started ====="

GREENLIGHT_DIR="/var/www/greenlight"

# ======== STOP SERVICES ========
echo "[1] Stopping Greenlight service..."
sudo systemctl stop greenlight || true
sudo systemctl disable greenlight || true
sudo rm -f /etc/systemd/system/greenlight.service
sudo systemctl daemon-reload

echo "[2] Stopping BigBlueButton (bbb-html5 + core services)..."
sudo systemctl stop bbb-html5 || true
sudo systemctl stop bbb-apps-akka || true
sudo systemctl stop bbb-fsesl-akka || true
sudo systemctl stop freeswitch || true
sudo systemctl stop bbb-webrtc-sfu || true
sudo systemctl stop bbb-web || true
sudo systemctl stop bbb-libreoffice || true
sudo systemctl stop bbb-transcode-akka || true
sudo systemctl stop nginx || true

# ======== REMOVE GREENLIGHT APP ========
echo "[3] Removing Greenlight files..."
sudo rm -rf "$GREENLIGHT_DIR"

# ======== REMOVE RUBY (rbenv) ========
echo "[4] Removing Ruby/rbenv..."
sudo rm -rf /usr/local/rbenv

# ======== REMOVE DATABASES & USER ========
echo "[5] Dropping PostgreSQL Greenlight databases and user..."
cd /tmp
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_production;" || true
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_development;" || true
sudo -u postgres psql -c "DROP USER IF EXISTS greenlight_user;" || true

# ======== REMOVE NGINX CONFIGS ========
echo "[6] Removing Nginx Greenlight config
