#!/bin/bash
set -e

# Must run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo $0"
  exit 1
fi

LOG_FILE="/var/log/ruby_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Installing Ruby 3.1 via rbenv (Prebuilt Tarballs, No PPA) ====="

# -----------------------------
# 1. Update system
# -----------------------------
apt-get update -y
apt-get upgrade -y

# -----------------------------
# 2. Install dependencies
# -----------------------------
apt-get install -y curl git build-essential libssl-dev zlib1g-dev \
  libreadline-dev libyaml-dev libffi-dev libgdbm-dev libncurses5-dev \
  autoconf bison libgmp-dev

# -----------------------------
# 3. Install rbenv + ruby-build
# -----------------------------
if [ -d "/usr/local/rbenv" ]; then
    echo "[INFO] Removing existing rbenv..."
    rm -rf /usr/local/rbenv
fi

git clone https://github.com/rbenv/rbenv.git /usr/local/rbenv
git clone https://github.com/rbenv/ruby-build.git /usr/local/rbenv/plugins/ruby-build
chmod -R 755 /usr/local/rbenv
chown -R root:root /usr/local/rbenv

export RBENV_ROOT="/usr/local/rbenv"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"

# -----------------------------
# 4. Install Ruby versions (prebuilt tarballs)
# -----------------------------
export RUBY_BUILD_MIRROR_URL="https://cache.ruby-lang.org/pub/ruby"

echo "[INFO] Installing Ruby 3.1.6 (global)..."
rbenv install -s 3.1.6

echo "[INFO] Installing Ruby 3.1.0 (for Greenlight)..."
rbenv install -s 3.1.0

rbenv global 3.1.6
rbenv rehash

# -----------------------------
# 5. Install bundler
# -----------------------------
gem install bundler --no-document
rbenv rehash

# -----------------------------
# 6. Verify installation
# -----------------------------
echo "[INFO] Ruby versions installed:"
ruby -v
gem -v
bundle -v

echo "===== Ruby 3.1 Installation Completed Successfully ====="
echo "Log file: $LOG_FILE"
