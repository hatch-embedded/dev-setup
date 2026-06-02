#!/usr/bin/env bash
set -euo pipefail

# Installs the GitHub Actions runner under the hatch-runner service account,
# then clones rest_plus and runs tools/setup/setup.sh to install ESP-IDF.
#
# Usage: curl -fsSL .../sh/setup_runner.sh | sudo bash -s -- <REGISTRATION-TOKEN>
# Must be run as root (via sudo).

RUNNER_VERSION="2.319.1"
RUNNER_USER="hatch-runner"
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"
GIT_DIR="/home/${RUNNER_USER}/git"
REST_PLUS_DIR="${GIT_DIR}/rest_plus"
REPO_URL="https://github.com/hatch-baby/rest_plus"

TOKEN="${1:?Usage: sudo bash setup_runner.sh <REGISTRATION-TOKEN>}"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use: sudo bash -s -- <TOKEN>" >&2
    exit 1
fi

# The user who invoked sudo — used to clone with their GitHub SSH key.
INVOKING_USER="${SUDO_USER:-$(logname 2>/dev/null || echo admin)}"

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

# ---- Clone rest_plus ----

if [ -d "${REST_PLUS_DIR}/.git" ]; then
    echo "⏭  | SKIP clone (rest_plus already exists at ${REST_PLUS_DIR})"
else
    echo "Cloning rest_plus (using ${INVOKING_USER}'s GitHub SSH key)..."
    sudo -u "${INVOKING_USER}" git clone \
        git@github.com:hatch-baby/rest_plus.git \
        "${REST_PLUS_DIR}"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${GIT_DIR}"
    echo "✅ | CLONE rest_plus"
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
