#!/usr/bin/env bash
echo "Updating system..."
sudo apt-get -qq update -u -y --allow-releaseinfo-change
sudo apt-get -qq --fix-broken install
sudo dpkg --configure -a
sudo apt-get -qq full-upgrade -y
sudo apt-get -qq clean -y
sudo apt-get -qq --purge autoremove -y
sudo apt-get -qq autoclean -y
echo "System update complete"
