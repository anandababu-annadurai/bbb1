#!/bin/bash
set -e

# ======== USER INPUT ========
read -p "Enter your domain name (e.g., bbb.example.com): " DOMAIN
read -p "Enter your email address (for Let's Encrypt SSL): " EMAIL
read -sp "Enter password for Greenlight DB user: " GREENLIGHT_DB_PASS
echo
GREENLIGHT_DIR="/var/www/greenlight"

echo "===== Starting BBB + Greenlight Full Installation ====="
echo "Domain: $DOMAIN"
echo "Email: $EMAIL"

# ======== SYSTEM UPDATE ========
echo "[1] Updating system packages..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl git gnupg2 build-essential zlib1g-dev lsb-release ufw libssl-dev libreadline-dev libyaml-dev libffi-dev libgdbm-dev

# ======== HOSTNAME ========
echo "[2] Setting hostname..."
sudo hostnamectl set-hostname $DOMAIN
echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts

# ======== INSTALL RUBY 3.3 VIA RBENV ========
echo "[3] Installing Ruby 3.3 via rbenv..."
if [ ! -d "$HOME/.rbenv" ]; then
    git clone https://github.com/rbenv/rbenv.git ~/.rbenv
    cd ~/.rbenv && src/configure && make -C src
    echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
    echo 'eval "$(rbenv init -)"' >> ~/.bashrc
    source ~/.bashrc
    git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
    export
