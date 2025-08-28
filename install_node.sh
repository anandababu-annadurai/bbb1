#!/bin/bash
set -e

LOG_FILE="/var/log/node_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Node.js + Yarn Installation ====="

# Remove conflicting npm
apt-get remove -y npm || true

# Install Node.js 20.x via Nodesource (includes npm)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Enable corepack + Yarn
corepack enable
npm install -g yarn

echo "Node.js version: $(node -v)"
echo "npm version: $(npm -v)"
echo "Yarn version: $(yarn -v)"
