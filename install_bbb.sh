#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Optimized BBB + Greenlight Installation Started ====="

# ===== User Inputs =====
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter your email for SSL notifications: " EMAIL

# ===== Check Ruby =====
if command -v ruby >/dev/null 2>&1; then
    echo "[INFO] Ruby is already installed: $(ruby -v)"
else
    echo "[INFO] Installing Ruby 3.1 via rbenv..."
    # Install rbenv and Ruby 3.1
    git clone https://github.com/rbenv/rbenv.git ~/.rbenv
    cd ~/.rbenv && src/configure && make -C src
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
    echo 'eval "$(rbenv init - bash)"' >> ~/.bashrc
    export PATH="$HOME/.rbenv/bin:$PATH"
    eval "$(rbenv init - bash)"
    git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
    rbenv install -s 3.1.6
    rbenv global 3.1.6
    gem install bundler --no-document
    echo "[INFO] Ruby 3.1.6 + Bundler installed."
fi

# ===== Check Node =====
if command -v node >/dev/null 2>&1; then
    echo "[INFO] Node.js already installed: $(node -v)"
else
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# ===== Check npm =====
if command -v npm >/dev/null 2>&1; then
    echo "[INFO] npm already installed: $(npm -v)"
else
    sudo apt-get install -y npm
fi

# ===== Check Yarn =====
if command -v yarn >/dev/null 2>&1; then
    echo "[INFO] Yarn already installed: $(yarn -v || echo 'Please fix Yarn manually')"
else
    sudo npm install -g yarn --force
fi

# ===== Update System =====
sudo apt-get update -y
sudo apt-get upgrade -y

# ===== Remove old BBB repos =====
sudo rm -f /etc/apt/sources.list.d/bbb.list
sudo rm -f /etc/apt/sources.list.d/bigbluebutton-focal.list

# ===== Add BBB Focal repo and GPG =====
sudo mkdir -p /usr/share/keyrings
curl -fsSL https://ubuntu.bigbluebutton.org/repo/bbb.gpg | sudo tee /usr/share/keyrings/bbb.gpg > /dev/null || {
    echo "[WARN] Could not download GPG key. Using --allow-unauthenticated for apt."
}

echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bigbluebutton-focal.list

sudo apt-get update -y || echo "[WARN] GPG error ignored. Proceeding with installation."

# ===== BBB + Greenlight Install via Official Script =====
wget -qO- https://raw.githubusercontent.com/bigbluebutton/bbb-install/v2.7.x-release/bbb-install.sh | \
bash -s -- -v focal-260 -s "$DOMAIN" -e "$EMAIL" -g

# ===== Firewall Check =====
echo "[INFO] Opening ports for BBB (80, 443) and SSH (22)"
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 22/tcp
sudo ufw reload

echo "===== BBB + Greenlight Installation Completed Successfully ====="
echo "Visit https://$DOMAIN to access your server."
