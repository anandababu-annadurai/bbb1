echo "[CLEAN] Stopping Greenlight service if running..."
sudo systemctl stop greenlight || true
sudo systemctl disable greenlight || true
sudo rm -f /etc/systemd/system/greenlight.service
sudo systemctl daemon-reload

echo "[CLEAN] Dropping old PostgreSQL databases and user..."
cd /tmp
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_production;" || true
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_development;" || true
sudo -u postgres psql -c "DROP USER IF EXISTS greenlight;" || true

echo "[CLEAN] Removing old rbenv installation..."
sudo rm -rf /usr/local/rbenv || true

echo "[CLEAN] Killing any leftover Greenlight processes..."
sudo pkill -f greenlight || echo "No greenlight processes found"

echo "[CLEAN] Restarting nginx..."
sudo systemctl restart nginx
