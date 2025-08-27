# Stop all services
sudo systemctl stop greenlight.service
sudo systemctl stop nginx
sudo systemctl disable greenlight.service

# Remove Greenlight installation
sudo rm -rf /var/www/greenlight
sudo rm -f /etc/systemd/system/greenlight.service
sudo rm -f /etc/nginx/sites-enabled/greenlight
sudo rm -f /etc/nginx/sites-available/greenlight

# Clean up database
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_development;"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS greenlight_production;"
sudo -u postgres psql -c "DROP USER IF EXISTS greenlight;"

# Remove rbenv (optional, but recommended for clean install)
sudo rm -rf /usr/local/rbenv

# Clean up any remaining processes
sudo pkill -f greenlight || echo "No greenlight processes found"

# Restart nginx to default state
sudo systemctl start nginx
