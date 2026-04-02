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

If needed, you can also run the script without the additional arguments:

```ps1
irm https://hatch-embedded.github.io/dev-setup/win/configure_ssh.ps1 | iex
```

## Extra Arguments

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
```
