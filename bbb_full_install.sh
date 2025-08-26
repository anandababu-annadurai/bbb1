#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_full_install.log"
STEP_FILE="/var/log/bbb_install_step.log"

exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== BBB + Greenlight Installation Started ====="
echo "Log file: $LOG_FILE"

# ======== USER INPUT ========
if [ ! -f "$STEP_FILE" ]; then
    read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
    read -p "Enter your email address (for Let's Encrypt SSL): " EMAIL
    read -sp "Enter password for Greenlight DB user: " GREENLIGHT_DB_PASS
    echo
    GREENLIGHT_DIR="/var/www/greenlight"
    echo "STEP=0" > "$STEP_FILE"
else
    echo "Resuming installation from last step..."
    source "$STEP_FILE"
    echo "Last completed step: $STEP"
fi

# ======== FUNCTION TO UPDATE STEP ========
update_step() {
    STEP=$1
    echo "STEP=$STEP" > "$STEP_FILE"
}

# ======== STEP 1: SYSTEM UPDATE ========
if [ "$STEP" -lt 1 ]; then
    echo "[1] Updating system packages..."
    sudo apt update -y && sudo apt upgrade -y
    sudo apt install -y software-properties-common curl git gnupg2 build-essential \
        zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev wget
    update_step 1
fi

# ======== STEP 2: REMOVE OLD BRIGHTBOX PPA ========
if [ "$STEP" -lt 2 ]; then
    if [ -f /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list ]; then
        echo "[2] Removing old Brightbox Ruby PPA..."
        sudo rm /etc/apt/sources.list.d/brightbox-ubuntu-ruby-ng-jammy.list
    fi
    sudo apt update
    update_step 2
fi

# ======== STEP 3: HOSTNAME ========
if [ "$STEP" -lt 3 ]; then
    echo "[3] Setting hostname..."
    sudo hostnamectl set-hostname $DOMAIN
    echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts
    update_step 3
fi

# ======== STEP 4: INSTALL BBB ========
if [ "$STEP" -lt 4 ]; then
    echo "[4] Installing BigBlueButton..."
    if ! wget -qO- https://ubuntu.bigbluebutton.org/bbb-install.sh | sudo bash -s -- -v jammy-27 -s $DOMAIN -e $EMAIL -g; then
        echo "⚠️ Installation failed. Do you want to run rollback? (y/n)"
        read ROLLBACK
        if [ "$ROLLBACK" == "y" ]; then
            sudo bbb-install --rollback
            echo "Rollback complete. Exiting."
            exit 1
        else
            echo "Skipping rollback. Check errors manually."
            exit 1
        fi
    fi
    update_step 4
fi

# ======== STEP 5: DEPENDENCIES ========
if [ "$STEP" -lt 5 ]; then
    echo "[5] Installing Nginx, PostgreSQL, Node.js, Yarn..."
    sudo apt install -y nginx postgresql postgresql-contrib nodejs
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/yarn.gpg
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
    sudo apt update
    sudo apt install -y yarn
    update_step 5
fi

# ======== STEP 6: RBENV AND RUBY ========
if [ "$STEP" -lt 6 ]; then
    echo "[6] Installing Ruby 3.3.6 via rbenv..."
    export RBENV_ROOT="$HOME/.rbenv"
    export PATH="$RBENV_ROOT/bin:$PATH"

    if [ ! -d "$RBENV_ROOT" ]; then
        git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
        cd "$RBENV_ROOT" && src/configure && make -C src
        echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
        echo 'eval "$(rbenv init -)"' >> ~/.bashrc
        source ~/.bashrc
    fi

    if [ ! -d "$RBENV_ROOT/plugins/ruby-build" ]; then
        git clone https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
    fi
    export PATH="$RBENV_ROOT/plugins/ruby-build/bin:$PATH"

    if ! rbenv versions | grep -q "3.3.6"; then
        echo "Compiling Ruby 3.3.6..."
        if ! rbenv install -s 3.3.6 -j 1; then
            echo "Retrying Ruby build..."
            rbenv uninstall -f 3.3.6 || true
            rbenv install -s 3.3.6 -j 1
        fi
    fi

    rbenv global 3.3.6
    update_step 6
fi

# ======== STEP 7: GREENLIGHT INSTALL ========
if [ "$STEP" -lt 7 ]; then
    echo "[7] Installing Greenlight..."
    cd /var/www
    if [ ! -d greenlight ]; then
        sudo git clone https://github.com/bigbluebutton/greenlight.git
    fi
    cd greenlight
    rbenv local 3.3.6
    gem install bundler
    bundle install
    yarn install
    update_step 7
fi

# ======== STEP 8: DATABASE ========
if [ "$STEP" -lt 8 ]; then
    echo "[8] Configuring PostgreSQL..."
    sudo -u postgres psql -c "CREATE USER greenlight WITH PASSWORD '$GREENLIGHT_DB_PASS';" || true
    sudo -u postgres psql -c "CREATE DATABASE greenlight_development OWNER greenlight;" || true
    bundle exec rake db:migrate
    update_step 8
fi

# ======== STEP 9: GREENLIGHT CONFIG ========
if [ "$STEP" -lt 9 ]; then
    echo "[9] Setting Greenlight secrets..."
    SECRET_KEY=$(bundle exec rake secret)
    BBB_SECRET=$(bbb-conf --secret)
    cat > config/application.yml <<EOL
SECRET_KEY_BASE: $SECRET_KEY
BIGBLUEBUTTON_ENDPOINT: https://$DOMAIN/bigbluebutton/
BIGBLUEBUTTON_SECRET: $BBB_SECRET
EOL
    update_step 9
fi

# ======== STEP 10: FIREWALL ========
if [ "$STEP" -lt 10 ]; then
    echo "[10] Configuring firewall..."
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw allow 3478/tcp
    sudo ufw allow 5222:5223/tcp
    sudo ufw allow 16384:32768/udp
    sudo ufw --force enable
    update_step 10
fi

# ======== STEP 11: NGINX ========
if [ "$STEP" -lt 11 ]; then
    echo "[11] Nginx reverse proxy..."
    cat > /etc/nginx/sites-available/greenlight <<EOL
server {
    listen 80;
    server_name $DOMAIN;

    root $GREENLIGHT_DIR/public;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Ssl on;
    }
}
EOL
    sudo ln -sf /etc/nginx/sites-available/greenlight /etc/nginx/sites-enabled/
    sudo nginx -t
    sudo systemctl restart nginx
    update_step 11
fi

# ======== STEP 12: SYSTEMD ========
if [ "$STEP" -lt 12 ]; then
    echo "[12] Creating systemd service..."
    cat > /etc/systemd/system/greenlight.service <<EOL
[Unit]
Description=Greenlight Rails server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$GREENLIGHT_DIR
ExecStart=/usr/bin/bundle exec rails server -b 0.0.0.0 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
EOL
    sudo systemctl daemon-reload
    sudo systemctl enable greenlight.service
    sudo systemctl start greenlight.service
    update_step 12
fi

# ======== STEP 13: SSL ========
if [ "$STEP" -lt 13 ]; then
    echo "[13] Certbot SSL..."
    sudo apt install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
    update_step 13
fi

# ======== STEP 14: MAINTENANCE SCRIPT ========
if [ "$STEP" -lt 14 ]; then
    echo "[14] Creating maintenance script..."
    cat > /usr/local/bin/bbb_maintenance.sh <<'MAINTENANCE'
#!/bin/bash
set -e
DOMAIN="'$DOMAIN'"
GREENLIGHT_DIR="'$GREENLIGHT_DIR'"
EMAIL="'$EMAIL'"
sudo apt update && sudo apt upgrade -y
sudo apt install --only-upgrade -y bigbluebutton
if [ -d "$GREENLIGHT_DIR" ]; then
    cd "$GREENLIGHT_DIR"
    git pull origin main
    gem install bundler
    bundle install
    yarn install
    bundle exec rake db:migrate
    sudo systemctl restart greenlight.service
fi
sudo certbot renew --quiet
sudo systemctl reload nginx
bbb-conf --check
MAINTENANCE
    sudo chmod +x /usr/local/bin/bbb_maintenance.sh
    (crontab -l 2>/dev/null; echo "0 3 * * 0 /usr/local/bin/bbb_maintenance.sh >> /var/log/bbb_maintenance.log 2>&1") | crontab -
    update_step 14
fi

# ======== STEP 15: FINAL CHECK ========
if [ "$STEP" -lt 15 ]; then
    echo "[15] Running final BBB check..."
    bbb-conf --check
    update_step 15
fi

echo "===== Installation Complete! ====="
echo "Greenlight URL: https://$DOMAIN"
echo "Maintenance script runs every Sunday at 3 AM."
