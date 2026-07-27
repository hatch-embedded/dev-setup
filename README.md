# Hatch Embedded Linux Setup Script

This simple repository exists to provide our linux setup script from an easy to type public URL which can be fetched from a fresh linux install. Comprehensive documentation exists in the `rest_plus` repository, but in short...

## Supported OS

- Debian LTS/stable
- Ubuntu LTS/stable

## Usage

1. Boot into the machine and login with your user credentials created during installation.

2. Give yourself permission to use `sudo` commands using the root password created during installation.

```sh
su - -c "usermod -aG sudo $(logname) && apt install -y sudo"
exit
```

You will be prompted to log back in afterwards.

3. Download and run the configuration script from this repository:

```sh
sudo apt install -y curl
curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash
```

Answer the prompts and follow the instructions until the script exits successfully.

## Windows SSH Client Setup

At the end of the configuration script, a one-line PowerShell command is printed. Execute that command in a PowerShell terminal on your Windows workstation to configure key-based SSH access to the freshly configured linux machine.

You may also run the script without arguments and enter the arguments at runtime:

```ps1
irm https://hatch-embedded.github.io/dev-setup/win/configure_ssh.ps1 | iex
```

### Extra Arguments

Run with extra arguments like so:

```sh
curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash -s -- <args>
```

Here are the supported extra arguments:

```
--skip-git
    Skips the prompts and error check for setting up SSH access to github.com

--uninstall-gui
    At the end of configuration, prompts the user to disable and uninstall the desktop environment

--enable-watchdog
    Arms the hardware watchdog and panics the kernel on hung tasks, so the machine reboots itself instead of hanging silently. Intended for headless servers.

--tester
    Configures the machine as a HiL (Hardware-in-the-Loop) tester or unit tester instead of a developer workstation.
    Implies --skip-git and --enable-watchdog. See "HiL Tester Setup" below.
```

## HiL/Unit Tester Setup

Run the script with `--tester` to provision a machine as a tester machine:

```sh
curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash -s -- --tester
```

This mode performs the following steps in addition to the standard setup:

- **Installs `bluez`** for Bluetooth tooling
- **Creates the `hatch-runner` service account** — a system user with membership in the `dialout` and `docker` groups and passwordless sudo for `apt-get` and GitHub Actions runner service management (`systemctl start/stop/restart actions.runner.*`)
- **Hardens SSH** — sets `PermitRootLogin no` in `/etc/ssh/sshd_config` (and a drop-in under `sshd_config.d/` on Debian 12+) and reloads the SSH daemon
- **Saves hardware identifiers** to `/etc/hatch-tester-ids.txt` — includes hostname, machine-id, network interface MACs, and Bluetooth controller MACs
- **Arms the hardware watchdog** (see `--enable-watchdog`) so an unattended tester reboots itself instead of hanging silently

Git configuration and firmware repository cloning are skipped in tester mode.
