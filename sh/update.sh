#!/usr/bin/env bash
echo "Updating system..."
sudo apt-get -qq update -u -y --allow-releaseinfo-change
sudo apt-get -qq --fix-broken install
sudo dpkg --configure -a
sudo apt-get -qq full-upgrade -y
sudo apt-get -qq clean -y
sudo apt-get -qq --purge autoremove -y
sudo apt-get -qq autoclean -y
python3 -m pip install --upgrade pip > /dev/null 2>&1
echo "System update complete"
