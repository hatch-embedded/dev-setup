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
sudo apt install -y wget
wget -N https://hatch-embedded.github.io/dev-setup/configure.sh
chmod +x configure.sh
./configure.sh
```

Answer the prompts and follow the instructions until the script exits successfully.

When finished, feel free to `rm configure.sh`.
