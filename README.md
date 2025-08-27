sudo apt update && sudo apt upgrade -y
sudo apt install git curl -y

git reset --hard
git pull origin main

Clone the repo:

git clone https://github.com/anandababu-annadurai/bbb1.git
cd bbb1


Make it executable:
sudo chmod +x bbb_full_install.sh


Run it:
sudo ./bbb_full_install.sh




✅ Usage

Fresh install:
sudo bash greenlight_install.sh

Cleanup + reinstall:
sudo bash greenlight_install.sh --clean

