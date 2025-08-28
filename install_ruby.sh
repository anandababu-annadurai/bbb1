#!/bin/bash
set -e

LOG_FILE="/var/log/ruby_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Optimized Ruby Installation ====="

# Update system
apt-get update -y
apt-get upgrade -y

# Install build dependencies
apt-get install -y build-essential libssl-dev libreadline-dev zlib1g-dev \
  libyaml-dev libffi-dev libgdbm-dev libncurses5-dev autoconf bison libgmp-dev

# Create swap if needed (prevents hangs)
if ! swapon --show | grep -q '/swapfile'; then
    echo "[INFO] Creating 2G swapfile..."
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Install rbenv + ruby-build
if [ -d "/usr/local/rbenv" ]; then
    rm -rf /usr/local/rbenv
fi

git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
chmod -R 755 /usr/local/rbenv
chown -R root:root /usr/local/rbenv

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$PATH"

# Initialize rbenv
eval "$(rbenv init -)"

# Install Ruby versions
echo "[INFO] Installing Ruby 3.1.6 (global)..."
RUBY_BUILD_SKIP_EXISTING=true rbenv install -s 3.1.6

echo "[INFO] Installing Ruby 3.1.0 (Greenlight)..."
RUBY_BUILD_SKIP_EXISTING=true rbenv install -s 3.1.0

rbenv global 3.1.6
rbenv rehash

echo "[INFO] Ruby installation completed:"
ruby -v
gem -v
