#!/usr/bin/env bash
set -euo pipefail

# Installs the GitHub Actions runner under the hatch-runner service account,
# then copies rest_plus from a local path and runs tools/setup/setup.sh to install ESP-IDF.
#
# Usage: sudo bash setup_runner.sh <REGISTRATION-TOKEN> <PATH-TO-REST-PLUS>
# Example: sudo bash setup_runner.sh ABCxyz123 /media/admin/USB/rest_plus
# Must be run as root (via sudo).

RUNNER_VERSION="2.319.1"
RUNNER_USER="hatch-runner"
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"
GIT_DIR="/home/${RUNNER_USER}/git"
REST_PLUS_DIR="${GIT_DIR}/rest_plus"

TOKEN="${1:?Usage: sudo bash setup_runner.sh <REGISTRATION-TOKEN> <PATH-TO-REST-PLUS>}"
REST_PLUS_SRC="${2:?Usage: sudo bash setup_runner.sh <REGISTRATION-TOKEN> <PATH-TO-REST-PLUS>}"
REPO_URL="https://github.com/hatch-baby/rest_plus"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use: sudo bash setup_runner.sh <TOKEN> <PATH>" >&2
    exit 1
fi

if [ ! -d "$REST_PLUS_SRC" ]; then
    echo "Error: rest_plus not found at: $REST_PLUS_SRC" >&2
    exit 1
fi

echo ""
echo "========== HIL Tester Runner Setup =========="
echo ""

# ---- Install GitHub Actions runner ----

if [ -f "${RUNNER_DIR}/.runner" ]; then
    echo "⏭  | SKIP runner install (already configured at ${RUNNER_DIR})"
else
    echo "Installing GitHub Actions runner v${RUNNER_VERSION}..."
    sudo -u "${RUNNER_USER}" -H bash -c "
        set -euo pipefail
        mkdir -p '${RUNNER_DIR}'
        cd '${RUNNER_DIR}'
        curl -fsSL -o actions-runner.tar.gz \
          'https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz'
        tar xzf actions-runner.tar.gz
        rm actions-runner.tar.gz
        ./config.sh \
          --url '${REPO_URL}' \
          --token '${TOKEN}' \
          --name \"\$(hostname)\" \
          --unattended
    "
    "${RUNNER_DIR}/svc.sh" install "${RUNNER_USER}"
    "${RUNNER_DIR}/svc.sh" start
    echo "✅ | INSTALL GitHub Actions runner"
fi

# ---- Copy rest_plus ----

if [ -d "${REST_PLUS_DIR}/.git" ]; then
    echo "⏭  | SKIP copy (rest_plus already exists at ${REST_PLUS_DIR})"
else
    echo "Copying rest_plus from ${REST_PLUS_SRC}..."
    mkdir -p "${GIT_DIR}"
    cp -r "${REST_PLUS_SRC}" "${REST_PLUS_DIR}"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${GIT_DIR}"
    echo "✅ | COPY rest_plus"
fi

# ---- Install build dependencies ----

if [ -d "/home/${RUNNER_USER}/.espressif" ]; then
    echo "⏭  | SKIP build deps (ESP-IDF already installed)"
else
    echo ""
    echo "Installing ESP-IDF and build dependencies (~20-30 min)..."
    echo ""

    # Run as root with HOME set to hatch-runner's home so ESP-IDF tools land in
    # /home/hatch-runner/.espressif where the runner can find them during workflow runs.
    HOME="/home/${RUNNER_USER}" bash "${REST_PLUS_DIR}/tools/setup/setup.sh"

    # Fix ownership: files written by root need to be readable by hatch-runner.
    chown -R "${RUNNER_USER}:${RUNNER_USER}" \
        "/home/${RUNNER_USER}/.espressif" \
        "/home/${RUNNER_USER}/.ccache" \
        2>/dev/null || true

    echo "✅ | INSTALL build dependencies"
fi

echo ""
echo "========== Runner Setup Complete =========="
echo ""
echo "Next steps:"
echo "  1. Open a PR against hil-fleet adding this tester to inventory/hosts.yml"
echo "  2. Merge — the apply workflow will assign runner labels and push SSH keys"
echo "  3. Verify the runner appears as Idle in:"
echo "     https://github.com/hatch-baby/rest_plus/settings/actions/runners"
echo ""
