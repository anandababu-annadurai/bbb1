#!/bin/bash
set -e

echo "===== BigBlueButton Installation ====="

# Detect Ubuntu version
. /etc/os-release
UBUNTU_CODENAME=$VERSION_CODENAME

# Remove any old BBB repo
sudo rm -f /etc/apt/sources.list.d/bbb.list

# Add correct BBB repo based on codename
if [[ "$UBUNTU_CODENAME" == "focal" ]]; then
    echo "Configuring BBB 2.6 repo for Ubuntu 20.04 (focal)..."
    echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/focal-260 bigbluebutton-focal main" | sudo tee /etc/apt/sources.list.d/bbb.list
elif [[ "$UBUNTU_CODENAME" == "jammy" ]]; then
    echo "Configuring BBB 3.0 experimental repo for Ubuntu 22.04 (jammy)..."
    echo "deb [signed-by=/usr/share/keyrings/bbb.gpg] https://ubuntu.bigbluebutton.org/jammy-300 bigbluebutton-jammy main" | sudo tee /etc/apt/sources.list.d/bbb.list
else
    echo "ERROR: Unsupported Ubuntu release ($UBUNTU_CODENAME). BBB only supports focal (20.04) or jammy (22.04)."
    exit 1
fi

# Import BBB GPG key
wget -qO- https://ubuntu.bigbluebutton.org/repo/bbb.gpg | sudo gpg --dearmor -o /usr/share/keyrings/bbb.gpg

# Update packages
sudo apt update
