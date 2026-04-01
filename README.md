# Hatch Embedded Linux Setup Script

This simple repository exists to provide our linux setup script from an easy to type public URL which can be fetched from a fresh linux install.

## Usage

1. Boot into the OS and login with your user credentials created during installation.

2. Give yourself permission to use `sudo` commands using the root password created during installation.

```sh
su - -c 'usermod -aG sudo $(logname) && apt install -y sudo'
exit
```

You will be prompted to log back in afterwards.

3. Download and run the configuration script from this repository:

```sh
sudo apt install -y curl
curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash
```

Answer the prompts and follow the instructions until the script exits successfully.

When finished, feel free to `rm configure.sh`.

## Windows SSH Client Setup

At the end of `./configure.sh`, a one-line PowerShell command is printed.

Copy that command and paste it into a PowerShell terminal on your Windows workstation. It will:

- Download and execute `win/configure_ssh.ps1` directly from this repository (in-memory).
- Pass ip and user automatically.
- Configure SSH key-based access and local SSH client settings.

If needed, you can also run the script manually:

```powershell
$ip="<ip>"; $user="<user>"; irm https://hatch-embedded.github.io/dev-setup/win/configure_ssh.ps1 | iex
```
