#!/bin/bash
set -e

LOG_FILE="/var/log/node_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Node.js + Yarn Installation ====="

# Remove conflicting npm
apt-get remove -y npm || true

# Install Node.js 20.x via Nodesource
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Enable corepack and Yarn
corepack enable
npm install -g yarn

echo "Node.js: $(node -v)"
echo "npm: $(npm -v)"
echo "Yarn: $(yarn -v)"
