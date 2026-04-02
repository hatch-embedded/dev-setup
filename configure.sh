#!/usr/bin/env bash
set -euo pipefail

# Constant Config #

VERSION="2.4"
HOST="https://hatch-embedded.github.io/dev-setup"
SH="$HOME/sh"
REBOOT_FILE="/tmp/.dev-setup-reboot-pending"

# Dynamic Config #

SKIP_GIT=false
UNINSTALL_GUI=false
for arg in "$@"; do
    case "$arg" in
        --uninstall-gui) UNINSTALL_GUI=true ;;
        --skip-git) SKIP_GIT=true ;;
    esac
done

HAS_GUI=false
if [ "$(systemctl get-default)" != "multi-user.target" ]; then
    HAS_GUI=true
fi

IP=$(hostname -I | awk '{print $1}')
MAC=$(ip -br link | grep "$(ip -br addr show | awk -v ip="$IP" '$0 ~ ip {print $1}')" | awk '{print $3}')

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

    RESPONSE=${RESPONSE:-$DEFAULT_RESPONSE}
    RESPONSE=$(echo "$RESPONSE" | tr '[:upper:]' '[:lower:]')

    if [[ "$RESPONSE" == "y" ]]; then
        return 0
    else
        return 1
    fi
}

win_ssh_setup_cmd() {    
    local IP=$(hostname -I | awk '{print $1}')
    local MAC=$(ip -br link | grep "$(ip -br addr show | awk -v ip="$IP" '$0 ~ ip {print $1}')" | awk '{print $3}')
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

download_scripts() {
    local FILENAMES=("update.sh" "cron.sh")
    local FILEPATH

    mkdir -p "$SH"
    cd "$SH"
    for FILENAME in "${FILENAMES[@]}"; do
        FILEPATH="$SH/$FILENAME"
        wget -qN "$HOST/sh/$FILENAME"
        chmod +x "$FILEPATH"
    done
    cd - >/dev/null

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
    local PYTHON_PKG=(python3 python3-full python3-venv python3-virtualenv python3-setuptools python3-pip python-is-python3)

    apt_update
    apt_install "${SYS_PKG[@]}" "${UTIL_PKG[@]}" "${DEV_PKG[@]}" "${PYTHON_PKG[@]}"

    echo "✅ | INSTALL common packages"
}

install_ssh_server() {
    sudo ufw allow ssh >/dev/null
    sudo systemctl enable ssh --now >/dev/null 2>&1
    echo "✅ | INSTALL ssh server"
}

# Check https://docs.docker.com/engine/install/ for updates
install_docker() {
    # Determine OS
    . /etc/os-release

    case "${ID:-}" in
        ubuntu)
            repo_os="ubuntu"
            repo_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
            ;;
        debian)
            repo_os="debian"
            repo_codename="${VERSION_CODENAME:-}"
            ;;
        *)
            echo "Unsupported distribution: ${ID:-unknown}" >&2
            return 1
            ;;
    esac

    if [ -z "${repo_codename}" ]; then
        echo "Could not determine distribution codename" >&2
        return 1
    fi

    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/${repo_os}
Suites: ${repo_codename}
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
    local ESC_GIT_USER
    local ESC_GIT_EMAIL
    local ESC_PRIVKEY
    local EMAIL=""
    local USER
    local ENTRY
    local ERROR_LEVEL

    mkdir -p "$HOME/git"
    mkdir -p "$SSH_DIR"
    test -f "$SSH_CONFIG" || touch "$SSH_CONFIG"
    test -f "$SSH_HOSTS" || touch "$SSH_HOSTS"

    # Set global user/email config

    if [ -z "$GIT_USER" ]; then
        echo "Enter your git username:"
        input -p "> " USER
        git config --global user.name "$USER"
        GIT_USER=$(git config --global user.name)
    fi

    if [ -z "$GIT_EMAIL" ]; then
        if [ -z "$EMAIL" ]; then
            echo "Enter your git email:"
            input -p "> " EMAIL
        fi
        git config --global user.email "$EMAIL"
        GIT_EMAIL=$(git config --global user.email)
    fi

    # Generate SSH key if needed

    if [ ! -f "$PRIVKEY" ]; then
        ssh-keygen -t ed25519 -f "$PRIVKEY" -N "" -C "$GIT_EMAIL"
        eval "$(ssh-agent -s)"
        ssh-add "$PRIVKEY"
    fi

    # Update ssh config file

    # Escape variables for use in sed
    ESC_GIT_USER=$(echo "$GIT_USER" | sed 's/[]\/$*.^[]/\\&/g')
    ESC_GIT_EMAIL=$(echo "$GIT_EMAIL" | sed 's/[]\/$*.^[]/\\&/g')
    ESC_PRIVKEY=$(echo "$PRIVKEY" | sed 's/[]\/$*.^[]/\\&/g')

    if ! grep -q "# $ESC_GIT_USER|$ESC_GIT_EMAIL" "$SSH_CONFIG"; then
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
    ssh -T git@github.com >/dev/null 2>&1 || rc=$?
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
        ssh -T git@github.com >/dev/null 2>&1 || rc=$?

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
install_docker
install_claude
schedule_updates

if [ "$SKIP_GIT" != true ]; then
    configure_git
fi

if [ ! -d "$HOME/git/rest_plus" ]; then
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
echo "  $((NEXT_STEP++)). Re-run this script with --uninstall-gui to remove the desktop environment"
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
