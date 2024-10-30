#!/usr/bin/env bash

CUSTOM_LOCK="/tmp/update_script.lock"

cleanup() {
    flock -u 200
    rm -f "$CUSTOM_LOCK"
}

wait_for_locks() {
    for LOCK in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
        while sudo fuser $LOCK >/dev/null 2>&1; do
            sleep 1
        done
    done
}

exec 200>"$CUSTOM_LOCK"
flock 200 || exit 1

trap cleanup EXIT INT TERM

wait_for_locks

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
