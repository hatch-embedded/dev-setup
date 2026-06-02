#!/usr/bin/env bash
set -euo pipefail

# Grants the current user sudo access on a fresh Debian install.
# Run this at the console before configure.sh (before curl is available).
#
# Usage: bash bootstrap.sh

USER_NAME=$(logname)

echo "Granting sudo access to '${USER_NAME}'..."
su - -c "usermod -aG sudo ${USER_NAME} && apt install -y sudo"

echo ""
echo "Done. Log out and log back in, then run configure.sh."
