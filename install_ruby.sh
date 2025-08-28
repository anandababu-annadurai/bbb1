#!/bin/bash
set -e

LOG_FILE="/var/log/ruby_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== Installing Ruby 3.1 (Precompiled) ====="

# Update system
apt-get update -y
apt-get upgrade -y

# Install dependencies
apt-get install -y software-properties-common curl gnupg2 build-essential zlib1g-dev libssl-dev libreadline-dev

# Add Brightbox Ruby PPA for precompiled Ruby
apt-add-repository ppa:brightbox/ruby-ng -y
apt-get update -y

# Install Ruby 3.1
apt-get install -y ruby3.1 ruby3.1-dev

# Ensure gem and bundler are available
gem install bundler --no-document

# Verify installation
ruby -v
gem -v
bundle -v

echo "===== Ruby 3.1 Installation Completed Successfully ====="
