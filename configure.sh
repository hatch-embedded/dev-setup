#!/usr/bin/env bash
set -e
HOST="https://hatch-embedded.github.io/dev-setup"
SH="$HOME/sh"

# Functions

prompt_continue() {
    echo ""
    echo "Press any key to continue."
    read -n 1 -s
    echo ""
}

prompt_yes_no() {
    local PROMPT=$1
    local RESPONSE

    echo "$PROMPT"
    read -p "> " RESPONSE

    RESPONSE=${RESPONSE:-Y}
    RESPONSE=$(echo "$RESPONSE" | tr '[:upper:]' '[:lower:]')

    if [[ "$RESPONSE" == "y" ]]; then
        return 0
    else
        return 1
    fi
}

download_scripts() {
    local FILENAMES=("update.sh" "cron.sh")

    echo "Fetching setup scripts..."
    mkdir -p $SH && cd $SH
    for FILENAME in "${FILENAMES[@]}"; do
        FILEPATH=$SH/$FILENAME
        wget -nv -N $HOST/sh/$FILENAME
        chmod +x $FILEPATH
    done
}

update () {
    $SH/update.sh
}

enable_passwordless_sudo() {
    local LINE='%sudo ALL=(ALL) NOPASSWD: ALL'
    local FILEPATH='/etc/sudoers'

    if sudo grep -xsqF "$LINE" "$FILEPATH"; then
        echo "Passwordless sudo: OK"
        return 0 # already passwordless
    fi

    echo ""
    if prompt_yes_no "Passwordless sudo saves you from having to type your password every time you execute a command with sudo priveledges. The tradeoff is that root access becomes as secure as your user login method, which is fine in most cases. Would you like to enable passwordless sudo now [Y/n]?"; then
        echo "$LINE" | sudo tee -a "$FILEPATH"
        echo "Passwordless sudo: OK"
    else
        echo "Passwordless sudo: Skipped"
    fi
}

install_packages() {
    local SYS_PKG="ufw ca-certificates gnupg"
    local UTIL_PKG="wget curl openssh-server"
    local DEV_PKG="git cmake ccache docker"
    local PYTHON_PKG="python3 python3-venv python3-setuptools python3-pip"
    sudo apt-get install -qq -m -y $SYS_PKG $UTIL_PKG $DEV_PKG $PYTHON_PKG

    echo ""
    echo "Common packages installation complete"
}

install_docker() {
    # Check https://docs.docker.com/engine/install/debian/#installation-methods for updates
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    update

    sudo apt-get install -qq -m -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo docker run hello-world
    echo "Docker: OK"
}

update_firmware() {
    # Add firmware to apt sources
    local SOURCES_LIST="/etc/apt/sources.list"
    local BACKUP_FILE="/etc/apt/sources.list.bak"
    local TAGS=("contrib" "non-free" "non-free-firmware")

    if [ ! -f "$BACKUP_FILE" ]; then
        sudo cp $SOURCES_LIST $BACKUP_FILE
    fi

    # Process each line in sources.list
    sudo bash -c 'while read -r line; do
        if [[ -z "$line" || "$line" =~ ^# ]]; then
            echo "$line"
            continue
        fi

        new_line="$line"

        if ! [[ "$line" =~ contrib ]]; then
            new_line="$new_line contrib"
        fi

        if ! [[ "$line" =~ non-free[^-] ]]; then
            new_line="$new_line non-free"
        fi

        if ! [[ "$line" =~ non-free-firmware ]]; then
            new_line="$new_line non-free-firmware"
        fi

        echo "$new_line"
    done < /etc/apt/sources.list > /etc/apt/sources.list.tmp'

    # Replace the original file with the modified one
    sudo mv /etc/apt/sources.list.tmp /etc/apt/sources.list

    update
    sudo apt-get install -qq -m -y fwupd firmware-linux-nonfree

    # Reload fwupd service to ensure it's up-to-date
    sudo systemctl daemon-reload
    sudo systemctl restart fwupd

    # Refresh the list of available firmware updates
    echo "Checking for firmware updates..."
    sudo fwupdmgr refresh --force

    # Check for available updates
    sudo fwupdmgr get-updates || :
    sudo fwupdmgr update || :
    echo "Done checking for firmware updates. A reboot may or may not be nececssary"
}

update_cron_job() {
    $SH/cron.sh "update" "$SH/update.sh" "0 3 * * 1"
    echo System updates will be installed/applied every Monday at 3am
}

configure_ssh() {
    IP=$(hostname -I | awk '{print $1}')
    MAC=$(ip -br link | grep $(ip -br addr show | awk -v ip="$IP" '$0 ~ ip {print $1}') | awk '{print $3}')

    sudo ufw allow ssh
    sudo systemctl enable ssh --now

    echo ""
    echo ""
    echo "SSH server enabled and running. Please run $HOST/bat/configure-ssh.bat on the client PC for easy one-time SSH setup - otherwise you may use the following command to manually connect:"
    echo "    ssh $(logname)@$IP"
    echo ""
    echo "You should also consider setting up a static DHCP rule for $MAC to $IP so this does not change. This can be done in your router's web portal. If you would like to access this machine from an external network, it's recommended you create a port forward rule from a random external port to $IP:22."
    echo ""
}

configure_git() {
    local SSH_DIR=$HOME/.ssh
    local SSH_CONFIG=$SSH_DIR/config
    local SSH_HOSTS=$SSH_DIR/known_hosts
    local PRIVKEY=$SSH_DIR/id_ed25519
    local PUBKEY=$PRIVKEY.pub
    local GIT_USER=$(git config --global user.name)
    local GIT_EMAIL=$(git config --global user.email)
    local ESC_GIT_USER
    local ESC_GIT_EMAIL
    local ESC_PRIVKEY
    local EMAIL
    local USER
    local ENTRY
    local ERROR_LEVEL

    mkdir -p $HOME/git
    mkdir -p $SSH_DIR
    test -f $SSH_CONFIG || touch $SSH_CONFIG
    test -f $SSH_HOSTS || touch $SSH_HOSTS

    # Set global user/email config

    if [ -z "$GIT_USER" ]; then
        echo "Enter your git username:"
        read -p "> " USER
        git config --global user.name "$USER"
        GIT_USER=$(git config --global user.name)
    fi

    if [ -z "$GIT_EMAIL" ]; then
        if [ -z "$EMAIL" ]; then
            echo "Enter your git email:"
            read -p "> " EMAIL
        fi
        git config --global user.email "$EMAIL"
        GIT_EMAIL=$(git config --global user.email)
    fi

    echo "git config: OK"

    # Generate SSH key if needed

    if [ ! -f $PRIVKEY ]; then
        ssh-keygen -t ed25519 -f $PRIVKEY -N "" -C "$GIT_EMAIL"
        eval "$(ssh-agent -s)"
        ssh-add $PRIVKEY
    fi

    # Update ssh config file

    # Escape variables for use in sed
    ESC_GIT_USER=$(echo "$GIT_USER" | sed 's/[]\/$*.^[]/\\&/g')
    ESC_GIT_EMAIL=$(echo "$GIT_EMAIL" | sed 's/[]\/$*.^[]/\\&/g')
    ESC_PRIVKEY=$(echo "$PRIVKEY" | sed 's/[]\/$*.^[]/\\&/g')

    if ! grep -q "# $ESC_GIT_USER|$ESC_GIT_EMAIL" $SSH_CONFIG; then
        ENTRY="# $GIT_USER|$GIT_EMAIL
Host github.com
HostName github.com
User git
IdentityFile $PRIVKEY"

        # add github to known hosts
        ssh-keygen -R github.com > /dev/null 2&>1 || :
        ssh-keyscan -H github.com >> $SSH_HOSTS
        rm -f $SSH_HOSTS.old*

        echo "$ENTRY" >> $SSH_CONFIG
        echo "Entry added to $SSH_CONFIG."
    fi

    # Test the key
    set +e
    ssh -T git@github.com 2>&1
    ERROR_LEVEL=$?
    set -e

    if [ $ERROR_LEVEL -eq 1 ]; then
        echo "git ssh key: OK"
    elif [ $ERROR_LEVEL -eq 255 ]; then
        echo ""
        echo ""
        echo "Below is your SSH key for git authentication. Please copy it and add it to your GitHub account (https://github.com/settings/keys) before continuing."
        echo ""
        cat $PUBKEY

        prompt_continue

        # Test again
        set +e
        ssh -T git@github.com 2>&1
        ERROR_LEVEL=$?
        set -e

        if [ $ERROR_LEVEL -eq 1 ]; then
            echo "git ssh key: OK"
        elif [ $ERROR_LEVEL -eq 255 ]; then
            echo "Failed to authenticate as $GIT_USER ($GIT_EMAIL) using $PRIVKEY. Please try again."
            return 1
        else
            echo "An unexpected error occurred."
            return 1
        fi
    else
        echo "An unexpected error occurred."
        return 1
    fi
}

uninstall_gui() {
    sudo systemctl set-default multi-user.target

    if systemctl is-active --quiet gdm3; then
        sudo systemctl stop gdm3
        sudo systemctl disable gdm3
    fi

    sudo apt-get remove -qq -y --purge gnome-core kde-plasma-desktop xfce4 lxde

    echo ""
    echo "GUI Uninstalled - Reboot with "sudo reboot" to apply changes"
}

echo ""
echo "Welcome to the interactive setup script for configuring a fresh Linux install to be suited for embedded firmware development at Hatch. This was tested on Debian 12 but was designed to be as portable as possible (i.e. it should work on Ubuntu)."

echo ""
echo "NOTE: This setup script is designed to be idempotent, meaning it may be restarted or executed multiple times without consequence."

prompt_continue

download_scripts
enable_passwordless_sudo
update
install_packages
install_docker
configure_ssh
prompt_continue
configure_git

echo ""

if prompt_yes_no "Would you like to install firmware updates right now [Y/n]?"; then
    update_firmware
fi

echo ""
if prompt_yes_no "Would you like to install a weekly cron job to keep your system up-to-date [Y/n]?"; then
    update_cron_job
fi

echo ""
if prompt_yes_no "Would you like to disable and uninstall any GUI components from your system [Y/n]?"; then
    uninstall_gui
fi

echo ""
echo "Configuration complete! Please see firmware repo for setup steps regarding building and flashing product firmware."
prompt_continue
echo ""
