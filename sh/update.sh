#!/usr/bin/env bash

CUSTOM_LOCK="/tmp/update_script.lock"

if [ -n "$CRON" ] && ! sudo -n true 2>/dev/null; then
    echo "This script requires passwordless sudo to run while in cron context."
    exit 1
fi

cleanup() {
    flock -u "$LOCK_FD"
    exec {LOCK_FD}>&-
    sudo rm -f "$CUSTOM_LOCK"
}

wait_for_locks() {
    local LOCK
    for LOCK in /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock; do
        while sudo fuser $LOCK >/dev/null 2>&1; do
            sleep 1
        done
    done
}

sudo touch "$CUSTOM_LOCK"
sudo chmod 666 "$CUSTOM_LOCK"

exec {LOCK_FD}>"$CUSTOM_LOCK" || exit 1
flock "$LOCK_FD" || exit 1

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
# sudo python3 -m pip install --upgrade pip > /dev/null 2>&1

echo "System update complete"
