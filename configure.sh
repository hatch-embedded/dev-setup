#!/usr/bin/env bash
set -e
HOST="https://hatch-embedded.github.io/dev-setup"
SH="$HOME/sh"
REBOOT_PENDING=0

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

    echo "$LINE" | sudo tee -a "$FILEPATH"
    echo "Passwordless sudo: OK"
}

install_packages() {
    local SYS_PKG="ufw ca-certificates gnupg"
    local UTIL_PKG="wget curl openssh-server"
    local DEV_PKG="git cmake ccache docker"
    local PYTHON_PKG="python3 python3-full python3-venv python3-virtualenv python3-setuptools python3-pip python-is-python3"
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
    
    if groups $(logname) | grep -qw docker; then
        echo "docker group: OK" 
    else
        echo "Adding user to docker group..."
        sudo usermod -a -G docker $(logname)

        echo "docker group: OK"
        echo "System restart via is required before you can use docker without sudo."
        REBOOT_PENDING=1
    fi

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
    echo "SSH server enabled and running. Please run $HOST/bat/configure-ssh.bat on your Windows PC for easy one-time SSH setup."
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

add_user_to_dialout() {
    if groups $(logname) | grep -qw dialout; then
        echo "dialout group: OK"
    else
        sudo usermod -a -G dialout $(logname)

        echo ""
        echo "User added to dialout group. System restart is required before you can use serial devices on this machine."
        REBOOT_PENDING=1
    fi
}

uninstall_gui() {
    sudo systemctl set-default multi-user.target

    if systemctl is-active --quiet gdm3; then
        sudo systemctl stop gdm3
        sudo systemctl disable gdm3
        REBOOT_PENDING=1
    fi

    sudo apt-get remove -qq -y --purge gnome-core kde-plasma-desktop xfce4 lxde

    echo ""
    echo "GUI Uninstalled - Restart to apply changes"
}

setup_rest_plus() {
    echo ""
    echo "Cloning 'rest_plus'..."

    mkdir -p $HOME/git
    cd $HOME/git
    git clone --progress --recursive git@github.com:hatch-baby/rest_plus.git
    
    echo ""
    echo "Setting up 'rest_plus'..."

    $HOME/git/rest_plus/tools/setup/setup.sh
}

echo ""
echo "Welcome to the interactive setup script for configuring a fresh Linux install to be suited for embedded firmware development at Hatch. This was tested on Debian 12 but was designed to be as portable as possible."

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
add_user_to_dialout

update_cron_job

echo ""
if prompt_yes_no "Would you like to disable and uninstall all desktop components from your system (only do this if you are going to use this machine as a headless server) [Y/n]?"; then
    uninstall_gui
fi

if [ ! -d "$HOME/git/rest_plus" ]; then
    echo ""
    setup_rest_plus
fi

echo ""
echo "Configuration complete! Please see the firmware repo for setup steps regarding building and flashing product firmware."

if [ $REBOOT_PENDING -eq 1 ]; then
    echo ""
    if prompt_yes_no "System restart is required for some changes to take effect. Would you like to do this now [Y/n]?"; then
        sudo reboot
    fi
fi

prompt_continue
echo ""
