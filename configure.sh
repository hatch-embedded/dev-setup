#!/usr/bin/env bash
set -euo pipefail

# Constant Config #

VERSION="2.5"
HOST="https://hatch-embedded.github.io/dev-setup"
SH="$HOME/sh"
REBOOT_FILE="/tmp/.dev-setup-reboot-pending"

WATCHDOG_DEVICE="/dev/watchdog0"
WATCHDOG_RUNTIME_SEC=60
WATCHDOG_REBOOT_SEC="10min"
WATCHDOG_HUNG_TASK_SEC=300
WATCHDOG_PANIC_SEC=30

# Dynamic Config #

SKIP_GIT=false
UNINSTALL_GUI=false
ENABLE_WATCHDOG=false
TESTER=false
for arg in "$@"; do
    case "$arg" in
        --uninstall-gui) UNINSTALL_GUI=true ;;
        --skip-git) SKIP_GIT=true ;;
        --enable-watchdog) ENABLE_WATCHDOG=true ;;
        --tester) TESTER=true; SKIP_GIT=true; ENABLE_WATCHDOG=true ;;
    esac
done

HAS_GUI=false
if command -v systemctl >/dev/null 2>&1; then
    if [ "$(systemctl get-default 2>/dev/null || echo multi-user.target)" != "multi-user.target" ]; then
        HAS_GUI=true
    fi
fi

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$IP" ]; then
    IFACE=$(ip -br addr show 2>/dev/null | awk -v ip="$IP" '$0 ~ ip {print $1; exit}')
    MAC=$(ip -br link show "$IFACE" 2>/dev/null | awk '{print $3}')
fi
IP="${IP:-<unknown>}"
MAC="${MAC:-<unknown>}"

# Functions #

input() {
    read "$@" </dev/tty
}

mark_reboot() {
    touch "$REBOOT_FILE"
}

reboot_pending() {
    test -f "$REBOOT_FILE"
}

# Writes stdin to $1, creating parent directories. Returns 0 only when the
# contents changed, so callers can skip reload side effects on repeat runs.
write_config() {
    local DEST="$1"
    local TMP
    TMP=$(mktemp)

    cat > "$TMP"

    if sudo cmp -s "$TMP" "$DEST"; then
        rm -f "$TMP"
        return 1
    fi

    sudo install -m 0644 -D "$TMP" "$DEST"
    rm -f "$TMP"
}

user() {
    local X="${SUDO_USER:-${LOGNAME:-${USER:-}}}"

    if [ -z "$X" ] || ! id -u "$X" >/dev/null 2>&1; then
        X="$(logname 2>/dev/null || true)"
    fi

    if [ -z "$X" ] || ! id -u "$X" >/dev/null 2>&1; then
        X="$(id -un)"
    fi

    echo "$X"
}

prompt_continue() {
    echo ""
    echo "Press any key to continue."
    input -n 1 -s
    echo ""
}

prompt_yes_no() {
    local DEFAULT_RESPONSE="y" # default "default" response
    local PROMPT
    local RESPONSE

    case "${1:-}" in
        --default-no)
            DEFAULT_RESPONSE="n"
            shift
            ;;
        --default-yes)
            DEFAULT_RESPONSE="y"
            shift
            ;;
    esac

    PROMPT="$1"

    echo "$PROMPT"
    input -r -p "> " RESPONSE

    RESPONSE="${RESPONSE:-$DEFAULT_RESPONSE}"
    RESPONSE="${RESPONSE,,}"

    if [[ "$RESPONSE" == "y" ]]; then
        return 0
    else
        return 1
    fi
}

win_ssh_setup_cmd() {
    echo "\$h='$IP';\$u='$(user)';\$p=22; irm $HOST/win/configure_ssh.ps1 | iex"
}

enable_passwordless_sudo() {
    local LINE='%sudo ALL=(ALL) NOPASSWD: ALL'
    local FILEPATH='/etc/sudoers'

    if ! sudo grep -xsqF "$LINE" "$FILEPATH"; then
        echo "$LINE" | sudo tee -a "$FILEPATH" >/dev/null
    fi

    echo "✅ | ENABLE passwordless sudo"
}

enable_sudoless_serial_port() {
    if ! groups "$(user)" | grep -qw dialout; then
        sudo usermod -a -G dialout "$(user)"
        mark_reboot
    fi

    echo "✅ | ENABLE sudoless serial port access"
}

create_hatch_runner() {
    local RUNNER_USER="hatch-runner"
    local SUDOERS_FILE="/etc/sudoers.d/hatch-runner"

    if ! id "$RUNNER_USER" &>/dev/null; then
        sudo useradd -r -m -s /bin/bash "$RUNNER_USER"
    fi

    for group in dialout docker; do
        if getent group "$group" >/dev/null 2>&1; then
            if ! groups "$RUNNER_USER" 2>/dev/null | grep -qw "$group"; then
                sudo usermod -a -G "$group" "$RUNNER_USER"
            fi
        fi
    done

    sudo tee "$SUDOERS_FILE" >/dev/null <<'EOF'
hatch-runner ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt-get *
hatch-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart actions.runner.*
hatch-runner ALL=(ALL) NOPASSWD: /bin/systemctl stop actions.runner.*
hatch-runner ALL=(ALL) NOPASSWD: /bin/systemctl start actions.runner.*
EOF
    sudo chmod 440 "$SUDOERS_FILE"
    sudo visudo -c -f "$SUDOERS_FILE" >/dev/null

    echo "✅ | CREATE hatch-runner service account"
}

harden_sshd_tester() {
    local SSHD_CONFIG="/etc/ssh/sshd_config"
    local DROPIN_DIR="/etc/ssh/sshd_config.d"
    local CHANGED=false

    if sudo grep -qE '^#?PermitRootLogin' "$SSHD_CONFIG"; then
        # Replace existing line (commented or not)
        local CURRENT
        CURRENT=$(sudo grep -E '^#?PermitRootLogin' "$SSHD_CONFIG" | head -1)
        if [ "$CURRENT" != "PermitRootLogin no" ]; then
            sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
            CHANGED=true
        fi
    else
        echo 'PermitRootLogin no' | sudo tee -a "$SSHD_CONFIG" >/dev/null
        CHANGED=true
    fi

    # On Debian 12+, sshd_config.d drop-ins can override the main config.
    # Write a high-priority drop-in so our setting wins regardless.
    if [ -d "$DROPIN_DIR" ]; then
        local DROPIN="$DROPIN_DIR/99-hatch-tester.conf"
        local DROPIN_CONTENT='PermitRootLogin no'
        if [ ! -f "$DROPIN" ] || ! sudo grep -qxF "$DROPIN_CONTENT" "$DROPIN" 2>/dev/null; then
            echo "$DROPIN_CONTENT" | sudo tee "$DROPIN" >/dev/null
            CHANGED=true
        fi
    fi

    if [ "$CHANGED" = true ]; then
        sudo systemctl reload-or-restart ssh
    fi

    echo "✅ | HARDEN sshd (PermitRootLogin no)"
}

save_hardware_ids() {
    local OUT_FILE="/etc/hatch-tester-ids.txt"

    # Collect bluetooth MACs — try bluetoothctl first, fall back to sysfs
    local BT_LINES=()
    if command -v bluetoothctl >/dev/null 2>&1; then
        while IFS= read -r line; do
            BT_LINES+=("  $line")
        done < <(bluetoothctl show 2>/dev/null | awk '/^Controller/{print $2}')
    fi
    if [ "${#BT_LINES[@]}" -eq 0 ]; then
        for ADDR_FILE in /sys/class/bluetooth/*/address; do
            [ -f "$ADDR_FILE" ] || continue
            BT_LINES+=("  $(basename "$(dirname "$ADDR_FILE")")  $(cat "$ADDR_FILE")")
        done
    fi

    {
        echo "hostname:    $(hostname)"
        echo "machine-id:  $(cat /etc/machine-id 2>/dev/null || echo unknown)"
        echo ""
        echo "network interfaces:"
        ip -br link show 2>/dev/null | grep -v '^lo ' | while read -r IFACE STATE MAC _; do
            case "$IFACE" in
                en*) TYPE="ethernet" ;;
                wl*) TYPE="wifi    " ;;
                *)   TYPE="other   " ;;
            esac
            echo "  $TYPE  $IFACE  $MAC"
        done
        echo ""
        echo "bluetooth:"
        if [ "${#BT_LINES[@]}" -gt 0 ]; then
            printf '%s\n' "${BT_LINES[@]}"
        else
            echo "  (none found)"
        fi
    } | sudo tee "$OUT_FILE" >/dev/null

    echo ""
    echo "======== Hardware Identifiers (saved to $OUT_FILE) ========"
    sudo cat "$OUT_FILE"
    echo "============================================================"
    echo ""
    echo "✅ | SAVE hardware identifiers"
}

download_scripts() {
    local FILENAMES=("update.sh" "cron.sh")
    local FILEPATH

    apt_install wget

    mkdir -p "$SH"
    for FILENAME in "${FILENAMES[@]}"; do
        FILEPATH="$SH/$FILENAME"
        if ! wget -qN --tries=3 --timeout=15 -O "$FILEPATH" "$HOST/sh/$FILENAME"; then
            if [ ! -f "$FILEPATH" ]; then
                echo "ERROR: Failed to download $FILENAME" >&2
                return 1
            fi
            echo "WARNING: Using previously downloaded $FILENAME" >&2
        fi
        chmod +x "$FILEPATH"
    done

    echo "✅ | INSTALL ~/sh/ scripts"
}

apt_update() {
    "$SH/update.sh" > /dev/null
}

apt_install() {
    sudo apt-get -qqfy install "$@"
}

apt_install_common() {
    local SYS_PKG=(ufw ca-certificates gnupg)
    local UTIL_PKG=(wget curl rsync openssh-server)
    local DEV_PKG=(git cmake ccache)
    local TESTER_PKG=()
    if [ "$TESTER" = true ]; then
        TESTER_PKG=(bluez)
    fi
    local PYTHON_PKG=(python3 python3-full python3-venv python3-virtualenv python3-setuptools python3-pip)

    # python-is-python3 is not available on Debian 11 (bullseye)
    if apt-cache show python-is-python3 >/dev/null 2>&1; then
        PYTHON_PKG+=(python-is-python3)
    fi

    apt_update
    apt_install "${SYS_PKG[@]}" "${UTIL_PKG[@]}" "${DEV_PKG[@]}" "${PYTHON_PKG[@]}" "${TESTER_PKG[@]}"

    echo "✅ | INSTALL common packages"
}

install_ssh_server() {
    sudo ufw allow ssh >/dev/null
    sudo systemctl enable ssh --now >/dev/null 2>&1
    echo "✅ | INSTALL ssh server"
}

enable_watchdog() {
    local WD_CONF="/etc/systemd/system.conf.d/watchdog.conf"
    local SYSCTL_CONF="/etc/sysctl.d/60-hang-detect.conf"

    if [ ! -e "$WATCHDOG_DEVICE" ]; then
        echo "⚠️ $WATCHDOG_DEVICE not present"
        return 0
    fi

    if write_config "$WD_CONF" <<EOF
[Manager]
RuntimeWatchdogSec=$WATCHDOG_RUNTIME_SEC
RebootWatchdogSec=$WATCHDOG_REBOOT_SEC
EOF
    then
        sudo systemctl daemon-reexec
    fi

    if write_config "$SYSCTL_CONF" <<EOF
kernel.hung_task_panic = 1
kernel.hung_task_timeout_secs = $WATCHDOG_HUNG_TASK_SEC
kernel.panic_on_oops = 1
kernel.panic = $WATCHDOG_PANIC_SEC
EOF
    then
        # -e: --system re-reads every distro-shipped sysctl.d file, and one
        # unknown key anywhere would abort this script under `set -e`.
        sudo sysctl -eq --system
    fi

    echo "✅ | ENABLE hardware watchdog"
}

# Check https://docs.docker.com/engine/install/ for updates
install_docker() {
    # Determine OS (read in subshell to avoid polluting global variables like VERSION)
    local REPO_OS REPO_CODENAME
    REPO_OS=$(. /etc/os-release && echo "${ID:-}")
    REPO_CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")

    case "${REPO_OS}" in
        ubuntu|debian) ;;
        *)
            echo "Unsupported distribution: ${REPO_OS:-unknown}" >&2
            return 1
            ;;
    esac

    if [ -z "${REPO_CODENAME}" ]; then
        echo "Could not determine distribution codename" >&2
        return 1
    fi

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/${REPO_OS}/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${REPO_OS}
Suites: ${REPO_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # Remove legacy one-line format repo to prevent duplicate apt targets.
    sudo rm -f /etc/apt/sources.list.d/docker.list

    apt_update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if ! groups "$(user)" | grep -qw docker; then
        sudo usermod -a -G docker "$(user)"
        mark_reboot
    fi

    sudo docker --version > /dev/null
    echo "✅ | INSTALL Docker"
}

install_claude() {
    local BIN_DIR="$HOME/.local/bin"
    local BASHRC="$HOME/.bashrc"
    local PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""

    if ! "$BIN_DIR/claude" --version >/dev/null 2>&1; then
        # https://code.claude.com/docs/en/setup
        curl -fsSL https://claude.ai/install.sh | bash >/dev/null
    fi

    touch "$BASHRC"
    if ! grep -Fqx "$PATH_LINE" "$BASHRC"; then
        echo "$PATH_LINE" >> "$BASHRC"
        mark_reboot
    fi

    echo "✅ | INSTALL Claude Code"
}

schedule_updates() {
    "$SH/cron.sh" "update" "$SH/update.sh" "0 3 * * 1" >/dev/null
    echo "✅ | SCHEDULE update cron job"
}

update_firmware() {
    # Add firmware to apt sources
    local SOURCES_LIST="/etc/apt/sources.list"
    local BACKUP_FILE="/etc/apt/sources.list.bak"

    if [ ! -f "$BACKUP_FILE" ]; then
        sudo cp "$SOURCES_LIST" "$BACKUP_FILE"
    fi

    # Process each line in sources.list
    sudo bash -c 'while read -r line; do
        if [[ -z "$line" || "$line" =~ ^# ]]; then
            echo "$line"
            continue
        fi

        new_line="$line"

        if ! [[ " $line " =~ [[:space:]]contrib[[:space:]] ]]; then
            new_line="$new_line contrib"
        fi

        if ! [[ " $line " =~ [[:space:]]non-free[[:space:]] ]]; then
            new_line="$new_line non-free"
        fi

        if ! [[ " $line " =~ [[:space:]]non-free-firmware[[:space:]] ]]; then
            new_line="$new_line non-free-firmware"
        fi

        echo "$new_line"
    done < /etc/apt/sources.list > /etc/apt/sources.list.tmp'

    # Replace the original file with the modified one
    sudo mv /etc/apt/sources.list.tmp /etc/apt/sources.list

    apt_update
    apt_install fwupd firmware-linux-nonfree

    # Reload fwupd service to ensure it's up-to-date
    sudo systemctl daemon-reload
    sudo systemctl restart fwupd

    # Refresh the list of available firmware updates
    echo "Checking for firmware updates..."
    sudo fwupdmgr refresh --force

    # Check for available updates
    sudo fwupdmgr get-updates || :
    sudo fwupdmgr update || :
    echo "Done checking for firmware updates. A reboot may or may not be necessary."
}

configure_git() {
    local SSH_DIR="$HOME/.ssh"
    local SSH_CONFIG="$SSH_DIR/config"
    local SSH_HOSTS="$SSH_DIR/known_hosts"
    local PRIVKEY="$SSH_DIR/id_ed25519"
    local PUBKEY="$PRIVKEY.pub"
    local GIT_USER
    GIT_USER=$(git config --global user.name 2>/dev/null || true)
    local GIT_EMAIL
    GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
    local GIT_USER_INPUT
    local ENTRY

    mkdir -p "$HOME/git"
    mkdir -p "$SSH_DIR"
    test -f "$SSH_CONFIG" || touch "$SSH_CONFIG"
    test -f "$SSH_HOSTS" || touch "$SSH_HOSTS"

    # Set global user/email config

    if [ -z "$GIT_USER" ]; then
        echo "Enter your git username:"
        input -p "> " GIT_USER_INPUT
        git config --global user.name "$GIT_USER_INPUT"
        GIT_USER=$(git config --global user.name)
    fi

    if [ -z "$GIT_EMAIL" ]; then
        echo "Enter your git email:"
        input -p "> " GIT_EMAIL
        git config --global user.email "$GIT_EMAIL"
        GIT_EMAIL=$(git config --global user.email)
    fi

    # Generate SSH key if needed

    if [ ! -f "$PRIVKEY" ]; then
        ssh-keygen -t ed25519 -f "$PRIVKEY" -N "" -C "$GIT_EMAIL"
        eval "$(ssh-agent -s)"
        ssh-add "$PRIVKEY"
    fi

    # Update ssh config file

    if ! grep -Fq "# $GIT_USER|$GIT_EMAIL" "$SSH_CONFIG"; then
        ENTRY="# $GIT_USER|$GIT_EMAIL
Host github.com
HostName github.com
User git
IdentityFile $PRIVKEY"

        # add github to known hosts
        ssh-keygen -R github.com >/dev/null 2>&1 || :
        ssh-keyscan -H github.com >> "$SSH_HOSTS"
        rm -f "$SSH_HOSTS".old*

        echo "$ENTRY" >> "$SSH_CONFIG"
    fi

    # Test the key (exit 1 = authenticated, GitHub just denies shell access)
    local rc=0
    ssh -T -o ConnectTimeout=10 git@github.com </dev/null >/dev/null 2>&1 || rc=$?
    if ! [ "$rc" -eq 1 ]; then
        echo ""
        echo "Below is your SSH key for git authentication. Please copy it and add it to your GitHub account (https://github.com/settings/keys) before continuing."
        echo ""
        cat "$PUBKEY"
        echo ""
        echo "Alternatively, you may wish to press CTRL+C to abort and resume from a Windows SSH session to allow for easier copy/paste of the key. Here is the PowerShell command to begin:"
        echo ""
        echo "$(win_ssh_setup_cmd)"
        echo ""

        prompt_continue

        rc=0
        ssh -T -o ConnectTimeout=10 git@github.com </dev/null >/dev/null 2>&1 || rc=$?

        if [ "$rc" -ne 1 ]; then
            echo "Failed to authenticate as $GIT_USER ($GIT_EMAIL) using $PRIVKEY. Please try again."
            return 1
        fi
    fi

    echo "✅ | CONFIGURE git"
}

setup_rest_plus() {
    local GIT_DIR="$HOME/git"
    local REPO_DIR="$GIT_DIR/rest_plus"
    mkdir -p "$GIT_DIR"

    if [ ! -d "$REPO_DIR" ]; then
        echo ""
        echo "Cloning 'rest_plus'..."
        git clone -q git@github.com:hatch-baby/rest_plus.git "$REPO_DIR"
    else
        git -C "$REPO_DIR" pull -q || true
    fi

    echo ""
    echo "Setting up 'rest_plus'..."

    "$REPO_DIR/tools/setup/setup.sh"
    echo "✅ | SETUP hatch-baby/rest_plus"
}

uninstall_gui() {
    sudo systemctl set-default multi-user.target

    if systemctl is-active --quiet gdm3; then
        sudo systemctl stop gdm3
        sudo systemctl disable gdm3
        mark_reboot
    fi

    sudo apt-get remove -qqy --purge gnome-core kde-plasma-desktop xfce4 lxde || true

    echo "✅ | UNINSTALL Desktop"
}

# Main Script #

echo ""
echo "========== Hatch dev-setup v$VERSION =========="
echo ""

enable_passwordless_sudo
enable_sudoless_serial_port
download_scripts
apt_install_common
install_ssh_server

if [ "$ENABLE_WATCHDOG" = true ]; then
    enable_watchdog
fi

install_docker
install_claude
schedule_updates

if [ "$SKIP_GIT" != true ]; then
    configure_git
fi

if [ "$TESTER" = true ]; then
    create_hatch_runner
    harden_sshd_tester
    save_hardware_ids
elif [ "$SKIP_GIT" != true ] && [ ! -d "$HOME/git/rest_plus" ]; then
    if prompt_yes_no "Would you like to clone and setup the firmware repository to '$HOME/git/rest_plus'? [Y/n]"; then
        setup_rest_plus
    fi
fi

if [ "$UNINSTALL_GUI" = true ] && [ "$HAS_GUI" = true ]; then
    echo ""
    if prompt_yes_no --default-no "Disable and uninstall all desktop components from your system (only do this if you are going to use this machine as a headless server) [y/N]?"; then
        uninstall_gui
        HAS_GUI=false
    fi
fi

NEXT_STEP=1

echo ""
echo "======== Configuration Complete! ========"
echo ""
echo "Here are some things you might want to do next:"
echo ""
echo "  $((NEXT_STEP++)). Read the hatch-baby/rest_plus documentation for build/flash/monitor instructions"

if [ -z "${SSH_CONNECTION:-}" ]; then
    echo ""
    echo "  $((NEXT_STEP++)). Setup remote SSH access from a Windows machine. Use this PowerShell command to get started:"
    echo ""
    echo "$(win_ssh_setup_cmd)"
fi

echo ""
echo "  $((NEXT_STEP++)). Setup a static DHCP rule in your router to permanently assign $IP to $MAC"

if [ "$HAS_GUI" = true ]; then
    echo ""
    echo "  $((NEXT_STEP++)). Uninstall the desktop enviornment by restarting the script with '--uninstall-gui' like so:"
    echo ""
    echo "curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash -s -- --uninstall-gui"
    echo ""
fi

if reboot_pending; then
    echo ""
    if prompt_yes_no "System reboot is required for some changes to take effect. Would you like to do this now [Y/n]?"; then
        rm -f "$REBOOT_FILE"
        sudo reboot
    fi
fi

echo ""
echo "Goodbye."
echo ""
