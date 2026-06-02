# HIL Tester Setup Guide

*This guide covers the end-to-end setup of a new HIL tester machine, from imaging the USB stick through to a verified Idle runner in GitHub.*

**Time:** ~1 hour wall-clock, ~15 minutes of active attention.

---

## Materials

- Windows PC (for flashing the USB stick)
- USB Drive (500 MB+)
- Beelink Mini-PC
- HDMI monitor + cable
- USB keyboard
- Ethernet cable

---

## Step 1 — Prepare Installation Media

1. Download the latest stable AMD64 Debian "netinst" ISO from [debian.org/CD/netinst](https://www.debian.org/CD/netinst).
2. Download the portable release of **Etcher** from [github.com/balena-io/etcher/releases](https://github.com/balena-io/etcher/releases) — look for `balenaEtcher-win32-x64-X.Y.Z.zip` under "Show all assets".
3. Insert the USB drive and use `balenaEtcher.exe` to flash the ISO to it.

> **WARNING:** This erases the USB drive. Back up any files first.

---

## Step 2 — Configure BIOS

1. Insert the USB drive into the Mini-PC. Connect power, HDMI, keyboard, and Ethernet into the **rightmost** port (viewed from the back).
2. Hold `F7`, press the power button, and wait for the boot selection menu. If you miss it, hold the power button for 5+ seconds to force off, then try again.
3. Select **Enter Setup** → navigate to `Chipset > PCH-IO Configuration > State After G3` → set to **S0 State**.

   This makes the machine auto-power-on after a power outage — required for an unattended tester.

4. Press `F4` to save and exit.

---

## Step 3 — Install Debian

1. Hold `F7` again at power-on and select your USB installation media from the boot menu.
2. Select **Install** and follow prompts using defaults, **except:**

   | Setting | Value |
   |---|---|
   | **Network interface** | Select `enp1s0` (rightmost Ethernet port) |
   | **Hostname** | `tester-NN` (e.g. `tester-03`) — use the next available number |
   | **Username** | `admin` — this is the permanent ops account, not a throwaway |
   | **Passwords** | Record both the root and admin passwords in LastPass |
   | **Disk partitioning** | Guided — use entire disk and set up LVM |
   | **Software selection** | `SSH server` and `standard system utilities` only (deselect everything else) |

> **WARNING:** All data on the factory OS is erased.

---

## Step 4 — Run Configuration Script

1. On the Mini-PC, log in as `admin` at the console.

2. Grant yourself sudo access:

   ```sh
   su - -c "usermod -aG sudo $(logname) && apt install -y sudo"
   exit
   ```

   Log back in after the `exit`.

3. Run the tester configuration script:

   ```sh
   sudo apt install -y curl
   curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash -s -- --tester
   ```

   This will:
   - Install common packages, Docker, SSH server
   - Create the `hatch-runner` service account
   - Install the Ansible bootstrap SSH key
   - Configure your git identity (enter your GitHub username and email when prompted, then add the displayed key to [github.com/settings/keys](https://github.com/settings/keys))
   - Harden sshd

   If prompted to reboot, do so before continuing.

---

## Step 5 — Assign a Static DHCP Lease

In the office router, create a static DHCP lease pinning this machine's MAC address to a fixed IP.

The script prints the machine's IP and MAC at the end. You can also find them with:

```sh
ip -br addr show
ip -br link show
```

Also add a line to `/etc/hosts` on the Ansible controller machine:

```
10.0.4.1NN   tester-NN
```

---

## Step 6 — Install the GitHub Actions Runner and Build Dependencies

1. In GitHub, go to **rest_plus → Settings → Actions → Runners → New self-hosted runner** (Linux / x64). Copy the registration token shown in the `./config.sh` command (the value after `--token`).

2. Back on the tester (still SSHed in as `admin`), run the script from the USB stick, passing the registration token and the path to the `rest_plus` folder on the USB stick:

   ```sh
   sudo bash /media/admin/USB/setup_runner.sh <REGISTRATION-TOKEN> /media/admin/USB/rest_plus
   ```

   This will:
   - Install the GitHub Actions runner under the `hatch-runner` account (~2 min)
   - Copy `rest_plus` from the USB stick (~1 min)
   - Install ESP-IDF and build dependencies (~20–30 min unattended)

   The script is idempotent — safe to re-run if anything fails.

3. Verify the runner appears as **Idle** (without any product labels yet) in [github.com/hatch-baby/rest_plus/settings/actions/runners](https://github.com/hatch-baby/rest_plus/settings/actions/runners).

---

## Step 7 — Connect Hardware

Attach the lamp to the tester via USB (ESP Prog adapter). Identify the serial port:

```sh
ls /dev/ttyUSB*
```

Note the port (e.g. `/dev/ttyUSB1`) — you'll need it for the inventory entry.

---

## Step 8 — Add to the hil-fleet Inventory

Open a PR against [hatch-baby/hil-fleet](https://github.com/hatch-baby/hil-fleet) adding a block to `inventory/hosts.yml`:

```yaml
tester-NN:
  ansible_host: 10.0.4.1NN      # the IP from Step 5
  product: restoreV5             # internal product name (see table below)
  capabilities:
    - esp-prog                   # always present
    # - power-relay              # add if a networked PDU is attached
  unit_test_port: /dev/ttyUSB1   # port from Step 7
```

**Product name reference:**

| Lamp attached | `product` value |
|---|---|
| Hatch Sleep Clock | `ha25` |
| Restore 3 | `restoreV5` |
| Restore 2 | `restoreV4` |
| Restore (Classic) | `restoreIot` |
| Rest+ | `restPlus` |
| Rest Mini | `restMini` |
| Rest 2nd Gen | `riot` |
| Rest+ 2nd Gen | `riotPlus` |
| Hatch Baby | `restBaby` |

Merge the PR. The apply workflow runs automatically and:
- Pushes the team's SSH keys to `admin`'s `authorized_keys`
- Disables password authentication
- Writes `/etc/hatch-tester.conf`
- Re-registers the runner with its steady-state labels (`hil`, `tester-<product>`, `has-esp-prog`, `embedded-unit-test`)

---

## Step 9 — Verify

- [ ] Runner shows **Idle** in GitHub with the correct label set
- [ ] `ssh admin@tester-NN` works with your personal SSH key (no password)
- [ ] `cat /etc/hatch-tester.conf` shows correct PRODUCT, CAPABILITIES, UNIT_TEST_PORT
- [ ] `grep PasswordAuthentication /etc/ssh/sshd_config` shows `PasswordAuthentication no`

---

## Troubleshooting

**Runner not showing up after Step 6**
Check the service: `sudo systemctl status actions.runner.*.service`

**ESP-IDF install failed mid-way**
Re-run the setup script — it will skip already-completed steps:
```sh
curl -fsSL https://hatch-embedded.github.io/dev-setup/sh/setup_runner.sh \
  | sudo bash -s -- <NEW-TOKEN>
```
New token needed because registration tokens expire after 1 hour.

**Wrong serial port in inventory**
Edit `unit_test_port` in `inventory/hosts.yml`, open a PR, merge. Ansible updates the runner's `.env` on next apply.

**Need to add someone's SSH key**
Edit `admin_authorized_keys` in `inventory/group_vars/all.yml`, open a PR, merge. No per-machine work needed.
