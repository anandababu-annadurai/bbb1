#!/bin/bash
set -e

LOG_FILE="/var/log/bbb_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "===== BigBlueButton Installation ====="

# Add BBB repository
wget -qO- https://ubuntu.bigbluebutton.org/repo/bigbluebutton.asc | gpg --dearmor -o /usr/share/keyrings/bbb.gpg
echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/xenial-250 bigbluebutton-xenial main" | tee /etc/apt/sources.list.d/bigbluebutton.list

apt-get update -y
apt-get install -y bigbluebutton

# Verify BBB
bbb-conf --check
