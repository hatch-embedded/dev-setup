# HIL Tester Fleet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the HIL tester fleet setup: extend `configure.sh` with a `--tester` mode, add a `setup_runner.sh` helper, and create the `hatch-baby/hil-fleet` Ansible repo that manages SSH keys, hardware labels, and runner config across all testers.

**Architecture:** Two phases. Phase 1 (`dev-setup`) adds the per-machine bootstrap scripts. Phase 2 (`hil-fleet`) creates the Ansible repo that adopts machines after bootstrap and manages them in steady state. Machines are provisioned once manually then owned by Ansible from that point on.

**Tech Stack:** Bash, Ansible (open-source core), GitHub Actions, Ansible Vault (for encrypted secrets in git)

---

## Pre-requisites (read before starting)

- You need SSH access to at least one real tester (or a local VM) to verify the configure.sh and setup_runner.sh changes end-to-end.
- You need admin access to `hatch-baby/rest_plus` on GitHub to generate a runner registration token for testing.
- `hatch-baby/hil-fleet` does not exist yet — you need to create it as a **private** repo on GitHub before Task 4. Do not push to it until it exists.

---

## Phase 1 — `hatch-embedded/dev-setup`

**Files touched:**
- Modify: `configure.sh`
- Create: `sh/setup_runner.sh`

---

### Task 1: Generate the Ansible controller key pair

This key is the bootstrap mechanism: its public half is hardcoded into `configure.sh` so fresh testers accept the Ansible controller before the full whitelist lands. This is a one-time operation.

**Files:** None — output is two key files you'll use in Tasks 2 and 6.

- [ ] **Step 1: Generate the key pair**

```bash
ssh-keygen -t ed25519 -C "ansible-controller@hatch" -f ~/.ssh/hil-fleet-controller
```

When prompted for a passphrase, press Enter (no passphrase — the private key is protected by being stored only in the vault and the GitHub Actions secret, not by a passphrase).

- [ ] **Step 2: Note both values for use later**

```bash
cat ~/.ssh/hil-fleet-controller       # private key — goes into Ansible Vault in Task 6
cat ~/.ssh/hil-fleet-controller.pub   # public key  — goes into configure.sh in Task 2
```

Keep this terminal open. You will paste these into Task 2 and Task 6.

- [ ] **Step 3: Commit nothing yet** — keys stay local until they are placed in the right locations.

---

### Task 2: Add `--tester` mode to `configure.sh`

**Files:**
- Modify: `configure.sh`

- [ ] **Step 1: Add the `BOOTSTRAP_KEY` constant and `TESTER` flag**

Open `configure.sh`. At the top of the "Constant Config" section (after `VERSION=`, `HOST=`, `SH=`, `REBOOT_FILE=`), add:

```bash
BOOTSTRAP_KEY="ssh-ed25519 AAAA_REPLACE_WITH_REAL_PUB_KEY ansible-controller@hatch"
```

Replace `AAAA_REPLACE_WITH_REAL_PUB_KEY` with the full public key content from Task 1 Step 2 (the single line from `hil-fleet-controller.pub`, minus the trailing newline).

Then in the "Dynamic Config" section, extend the arg-parsing loop (currently lines ~15–19):

```bash
SKIP_GIT=false
UNINSTALL_GUI=false
TESTER=false
for arg in "$@"; do
    case "$arg" in
        --uninstall-gui) UNINSTALL_GUI=true ;;
        --skip-git) SKIP_GIT=true ;;
        --tester) TESTER=true ;;
    esac
done
```

Note: `--tester` does NOT set `SKIP_GIT=true`. Admin still needs git access to later run `setup_runner.sh` which clones `rest_plus`.

- [ ] **Step 2: Add the three new functions**

Add these after the existing `enable_sudoless_serial_port()` function:

```bash
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

install_bootstrap_key() {
    local U
    U="$(user)"
    local SSH_DIR="/home/$U/.ssh"
    local AUTH_KEYS="$SSH_DIR/authorized_keys"

    sudo mkdir -p "$SSH_DIR"
    sudo chmod 700 "$SSH_DIR"
    sudo chown "$U:$U" "$SSH_DIR"
    sudo touch "$AUTH_KEYS"
    sudo chmod 600 "$AUTH_KEYS"
    sudo chown "$U:$U" "$AUTH_KEYS"

    if ! sudo grep -qF "$BOOTSTRAP_KEY" "$AUTH_KEYS" 2>/dev/null; then
        echo "$BOOTSTRAP_KEY" | sudo tee -a "$AUTH_KEYS" >/dev/null
    fi

    echo "✅ | INSTALL bootstrap SSH key"
}

harden_sshd_tester() {
    local SSHD_CONFIG="/etc/ssh/sshd_config"

    if sudo grep -qE '^#?PermitRootLogin' "$SSHD_CONFIG"; then
        sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
    else
        echo 'PermitRootLogin no' | sudo tee -a "$SSHD_CONFIG" >/dev/null
    fi

    sudo systemctl restart ssh
    echo "✅ | HARDEN sshd (PermitRootLogin no; password auth left on for Ansible bootstrap)"
}
```

- [ ] **Step 3: Modify the main script section**

Find this block near the bottom of `configure.sh`:

```bash
if [ "$SKIP_GIT" != true ]; then
    configure_git
fi

if [ "$SKIP_GIT" != true ] && [ ! -d "$HOME/git/rest_plus" ]; then
    if prompt_yes_no "Would you like to clone and setup the firmware repository to '$HOME/git/rest_plus'? [Y/n]"; then
        setup_rest_plus
    fi
fi
```

Replace it with:

```bash
if [ "$SKIP_GIT" != true ]; then
    configure_git
fi

if [ "$TESTER" = true ]; then
    create_hatch_runner
    install_bootstrap_key
    harden_sshd_tester
elif [ "$SKIP_GIT" != true ] && [ ! -d "$HOME/git/rest_plus" ]; then
    if prompt_yes_no "Would you like to clone and setup the firmware repository to '$HOME/git/rest_plus'? [Y/n]"; then
        setup_rest_plus
    fi
fi
```

- [ ] **Step 4: Also suppress the `--uninstall-gui` final prompt in tester mode**

Find the `--uninstall-gui` block near the end:

```bash
if [ "$UNINSTALL_GUI" = true ] && [ "$HAS_GUI" = true ]; then
```

No change needed there. But find the "Next steps" echo block at the very end and add a tester-specific message. After the existing `echo "  $((NEXT_STEP++)). Setup a static DHCP rule..."` line, add:

```bash
if [ "$TESTER" = true ]; then
    echo ""
    echo "  $((NEXT_STEP++)). Assign a static DHCP lease in the office router (IP: $IP, MAC: $MAC)"
    echo ""
    echo "  $((NEXT_STEP++)). Run setup_runner.sh with a registration token from:"
    echo "     https://github.com/hatch-baby/rest_plus/settings/actions/runners/new"
    echo ""
    echo "     curl -fsSL $HOST/sh/setup_runner.sh | sudo bash -s -- <TOKEN>"
fi
```

- [ ] **Step 5: Verify the script is valid bash**

```bash
bash -n configure.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 6: Commit**

```bash
git add configure.sh
git commit -m "feat: add --tester mode to configure.sh

Creates hatch-runner service account, installs Ansible bootstrap key,
and hardens sshd. Admin's git identity is still configured so they can
run setup_runner.sh to clone rest_plus."
```

---

### Task 3: Create `sh/setup_runner.sh`

**Files:**
- Create: `sh/setup_runner.sh`

- [ ] **Step 1: Create the file**

```bash
touch sh/setup_runner.sh
chmod +x sh/setup_runner.sh
```

- [ ] **Step 2: Write the script**

Write the following to `sh/setup_runner.sh`:

```bash
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
    cd "${RUNNER_DIR}"
    ./svc.sh install "${RUNNER_USER}"
    ./svc.sh start
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

echo ""
echo "========== Runner Setup Complete =========="
echo ""
echo "Next steps:"
echo "  1. Open a PR against hil-fleet adding this tester to inventory/hosts.yml"
echo "  2. Merge — the apply workflow will assign runner labels and push SSH keys"
echo "  3. Verify the runner appears as Idle in:"
echo "     https://github.com/hatch-baby/rest_plus/settings/actions/runners"
echo ""
```

- [ ] **Step 3: Verify the script is valid bash**

```bash
bash -n sh/setup_runner.sh
```

Expected: no output.

- [ ] **Step 4: Verify the runner version tarball URL is valid**

```bash
curl -fsI \
  "https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-linux-x64-2.319.1.tar.gz" \
  | head -5
```

Expected: `HTTP/2 302` (redirect to S3). If you get `404`, update `RUNNER_VERSION` in the script to the latest release from https://github.com/actions/runner/releases.

- [ ] **Step 5: Commit**

```bash
git add sh/setup_runner.sh
git commit -m "feat: add setup_runner.sh helper

Wraps GitHub Actions runner install + ESP-IDF setup into one idempotent
script. Operator runs it once per tester after configure.sh --tester."
```

---

### Task 4: End-to-end test of Phase 1

You need a VM (or spare machine) with a fresh Debian install to test this. If you don't have one available, mark this task as deferred and proceed to Phase 2 — Phase 2 can be written independently.

- [ ] **Step 1: In a fresh Debian VM, run configure.sh in tester mode**

```bash
sudo apt install -y curl
curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash -s -- --tester
```

Or, to test your local branch directly (substitute the actual IP of a local HTTP server or use scp):

```bash
bash /path/to/configure.sh --tester
```

- [ ] **Step 2: Verify hatch-runner user exists**

```bash
id hatch-runner
groups hatch-runner
```

Expected output contains `dialout` and `docker` in the groups list.

- [ ] **Step 3: Verify sudoers file is correct**

```bash
sudo cat /etc/sudoers.d/hatch-runner
sudo visudo -c
```

Expected: file contents match what was written; `visudo -c` exits 0 with "parsed OK".

- [ ] **Step 4: Verify bootstrap key is in admin's authorized_keys**

```bash
cat ~/.ssh/authorized_keys
```

Expected: the `ssh-ed25519 AAAA... ansible-controller@hatch` line appears.

- [ ] **Step 5: Verify PermitRootLogin is set**

```bash
grep PermitRootLogin /etc/ssh/sshd_config
```

Expected: `PermitRootLogin no`

- [ ] **Step 6: Verify password auth is still enabled (Ansible will disable it on first apply)**

```bash
grep PasswordAuthentication /etc/ssh/sshd_config
```

Expected: NOT `PasswordAuthentication no` (it should be commented out or missing, meaning default=yes).

- [ ] **Step 7: Test setup_runner.sh (requires a real registration token)**

In GitHub: go to `https://github.com/hatch-baby/rest_plus/settings/actions/runners/new` → select Linux/x64 → copy the `--token` value from the `./config.sh` command shown.

Then on the VM:

```bash
curl -fsSL https://hatch-embedded.github.io/dev-setup/sh/setup_runner.sh \
  | sudo bash -s -- <PASTE-TOKEN-HERE>
```

Expected: script completes without errors, runner appears as Idle in the GitHub runners list.

- [ ] **Step 8: Verify ESP-IDF is owned by hatch-runner**

```bash
ls -la /home/hatch-runner/.espressif/
```

Expected: files are owned by `hatch-runner`, not `root`.

---

## Phase 2 — `hatch-baby/hil-fleet` (new repo)

**Pre-condition:** Create the `hatch-baby/hil-fleet` private repo on GitHub before starting this phase. Do not initialize it with any files.

**Files to create (all new):**
```
ansible.cfg
inventory/hosts.yml
inventory/group_vars/all.yml
roles/common/tasks/main.yml
roles/common/handlers/main.yml
roles/users/tasks/main.yml
roles/users/templates/authorized_keys.j2
roles/tester-config/tasks/main.yml
roles/tester-config/templates/hatch-tester.conf.j2
roles/github-runner/tasks/main.yml
roles/github-runner/handlers/main.yml
playbooks/site.yml
playbooks/reboot.yml
playbooks/runner-update.yml
.github/workflows/apply.yml
.github/workflows/lint.yml
README.md
```

---

### Task 5: Repo scaffold and inventory

- [ ] **Step 1: Clone the new empty repo and set up the directory structure**

```bash
git clone git@github.com:hatch-baby/hil-fleet.git
cd hil-fleet
mkdir -p inventory/group_vars
mkdir -p roles/common/{tasks,handlers}
mkdir -p roles/users/{tasks,templates}
mkdir -p roles/tester-config/{tasks,templates}
mkdir -p roles/github-runner/{tasks,handlers}
mkdir -p playbooks
mkdir -p .github/workflows
```

- [ ] **Step 2: Create `ansible.cfg`**

```ini
[defaults]
inventory = inventory/hosts.yml
remote_user = admin
host_key_checking = False
stdout_callback = yaml
interpreter_python = auto_silent
private_key_file = ~/.ssh/hil-fleet-controller

[privilege_escalation]
become = True
become_method = sudo
become_ask_pass = False
```

- [ ] **Step 3: Create `inventory/hosts.yml`**

```yaml
all:
  hosts:
    tester-01:
      ansible_host: 10.0.4.101     # update with real IP
      product: restoreV5
      capabilities:
        - esp-prog
        - power-relay
      unit_test_port: /dev/ttyUSB1
    # Add more testers here following the same pattern.
    # tester-02:
    #   ansible_host: 10.0.4.102
    #   product: riot
    #   capabilities:
    #     - esp-prog
    #   unit_test_port: /dev/ttyUSB1
```

- [ ] **Step 4: Create `inventory/group_vars/all.yml`**

Add your real SSH public keys. The `ansible-controller` entry must match the public key from Task 1.

```yaml
# Human SSH keys for the admin account on every tester.
# To add/remove access: edit this list and open a PR.
# The ansible-controller entry must always be present — it is how
# Ansible SSHes into testers. Its public key is hardcoded into configure.sh.
admin_authorized_keys:
  - name: ansible-controller
    key: "ssh-ed25519 AAAA_REPLACE_WITH_REAL_PUB_KEY ansible-controller@hatch"
  - name: nash
    key: "ssh-ed25519 AAAA_YOUR_KEY_HERE nash@hatch.co"
  # Add more team members here.

# GitHub Actions runner
github_runner_version: "2.319.1"
github_runner_org: hatch-baby
github_runner_repo: rest_plus

# GitHub PAT for runner re-registration (Administration:write on rest_plus).
# Value is vault-encrypted. To edit:
#   ansible-vault edit inventory/group_vars/vault.yml
# Then reference it here:
github_pat: "{{ vault_github_pat }}"
```

- [ ] **Step 5: Create `inventory/group_vars/vault.yml` with the encrypted PAT**

First, create a real fine-grained PAT on GitHub: go to https://github.com/settings/tokens → Fine-grained tokens → Generate. Scope it to `hatch-baby/rest_plus` with `Administration: write` permission.

Then encrypt it:

```bash
ansible-vault create inventory/group_vars/vault.yml
```

You'll be prompted for a vault password — choose a strong one and store it in LastPass or your team's password manager. In the editor that opens, write:

```yaml
vault_github_pat: "github_pat_XXXXXXXXXX"
```

Save and close. The file is now encrypted at rest in git.

- [ ] **Step 6: Add a `.gitignore`**

```
# Never commit unencrypted secrets
.vault-pass
*.key
```

- [ ] **Step 7: Commit the scaffold**

```bash
git add ansible.cfg inventory/ .gitignore
git commit -m "feat: initial inventory scaffold"
```

---

### Task 6: Ansible roles — common and users

- [ ] **Step 1: Create `roles/common/tasks/main.yml`**

```yaml
- name: Set PasswordAuthentication no
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PasswordAuthentication'
    line: 'PasswordAuthentication no'
    state: present
  become: true
  notify: Restart sshd

- name: Set PermitRootLogin no
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: '^#?PermitRootLogin'
    line: 'PermitRootLogin no'
    state: present
  become: true
  notify: Restart sshd
```

- [ ] **Step 2: Create `roles/common/handlers/main.yml`**

```yaml
- name: Restart sshd
  ansible.builtin.service:
    name: ssh
    state: restarted
  become: true
```

- [ ] **Step 3: Create `roles/users/templates/authorized_keys.j2`**

```
{# Managed by Ansible — hatch-baby/hil-fleet. Do not edit by hand. #}
{% for entry in admin_authorized_keys %}
{{ entry.key }}
{% endfor %}
```

- [ ] **Step 4: Create `roles/users/tasks/main.yml`**

```yaml
- name: Ensure .ssh directory exists for admin
  ansible.builtin.file:
    path: /home/admin/.ssh
    state: directory
    owner: admin
    group: admin
    mode: '0700'
  become: true

- name: Write authorized_keys for admin
  ansible.builtin.template:
    src: authorized_keys.j2
    dest: /home/admin/.ssh/authorized_keys
    owner: admin
    group: admin
    mode: '0600'
  become: true
```

Note: this **replaces** the entire `authorized_keys` file on every apply. The `admin_authorized_keys` list in `all.yml` is the single source of truth. Anyone not in that list loses access on next apply.

- [ ] **Step 5: Commit**

```bash
git add roles/common roles/users
git commit -m "feat: common and users roles"
```

---

### Task 7: Ansible roles — tester-config and github-runner

- [ ] **Step 1: Create `roles/tester-config/templates/hatch-tester.conf.j2`**

```
# Managed by Ansible — hatch-baby/hil-fleet. Do not edit by hand.
HOSTNAME={{ inventory_hostname }}
PRODUCT={{ product }}
CAPABILITIES={{ capabilities | join(',') }}
UNIT_TEST_PORT={{ unit_test_port }}
```

- [ ] **Step 2: Create `roles/tester-config/tasks/main.yml`**

```yaml
- name: Write /etc/hatch-tester.conf
  ansible.builtin.template:
    src: hatch-tester.conf.j2
    dest: /etc/hatch-tester.conf
    owner: root
    group: root
    mode: '0644'
  become: true
  notify: Restart runner service
```

- [ ] **Step 3: Create `roles/github-runner/handlers/main.yml`**

```yaml
- name: Restart runner service
  ansible.builtin.shell: |
    cd /home/hatch-runner/actions-runner
    ./svc.sh stop || true
    ./svc.sh start
  become: true
  become_user: root
```

- [ ] **Step 4: Create `roles/github-runner/tasks/main.yml`**

```yaml
# Build the label string from inventory vars:
#   hil,tester-<product>,has-<cap1>,has-<cap2>,...,embedded-unit-test
- name: Compute runner labels
  ansible.builtin.set_fact:
    runner_labels: >-
      hil,tester-{{ product }},{{ capabilities | map('regex_replace', '^(.+)$', 'has-\1') | join(',') }},embedded-unit-test

- name: Get runner registration token from GitHub API
  ansible.builtin.uri:
    url: "https://api.github.com/repos/{{ github_runner_org }}/{{ github_runner_repo }}/actions/runners/registration-token"
    method: POST
    headers:
      Authorization: "Bearer {{ github_pat }}"
      Accept: "application/vnd.github+json"
    status_code: 201
  register: reg_token_response
  no_log: true

- name: Re-register runner with steady-state labels
  ansible.builtin.shell: |
    sudo -u hatch-runner -H \
      /home/hatch-runner/actions-runner/config.sh \
        --url "https://github.com/{{ github_runner_org }}/{{ github_runner_repo }}" \
        --token "{{ reg_token_response.json.token }}" \
        --name "{{ inventory_hostname }}" \
        --labels "{{ runner_labels }}" \
        --unattended \
        --replace
  become: true
  no_log: true

- name: Ensure .env file exists for runner
  ansible.builtin.file:
    path: /home/hatch-runner/actions-runner/.env
    state: touch
    owner: hatch-runner
    group: hatch-runner
    mode: '0600'
    modification_time: preserve
    access_time: preserve
  become: true

- name: Set UNIT_TEST_PORT in runner .env
  ansible.builtin.lineinfile:
    path: /home/hatch-runner/actions-runner/.env
    regexp: '^UNIT_TEST_PORT='
    line: "UNIT_TEST_PORT={{ unit_test_port }}"
  become: true
  notify: Restart runner service

- name: Ensure runner service is started and enabled
  ansible.builtin.shell: |
    SERVICE=$(find /etc/systemd/system -name 'actions.runner.*.service' | head -1 | xargs basename 2>/dev/null || echo "")
    if [ -n "$SERVICE" ]; then
      systemctl enable "${SERVICE}"
      systemctl is-active --quiet "${SERVICE}" || systemctl start "${SERVICE}"
    fi
  become: true
  register: runner_service_result
  changed_when: false
```

- [ ] **Step 5: Add the `tester-config` handler to `tester-config` role**

Create `roles/tester-config/handlers/main.yml`:

```yaml
- name: Restart runner service
  ansible.builtin.shell: |
    SERVICE=$(find /etc/systemd/system -name 'actions.runner.*.service' | head -1 | xargs basename 2>/dev/null || echo "")
    if [ -n "$SERVICE" ]; then
      systemctl restart "${SERVICE}"
    fi
  become: true
```

- [ ] **Step 6: Commit**

```bash
git add roles/tester-config roles/github-runner
git commit -m "feat: tester-config and github-runner roles"
```

---

### Task 8: Playbooks

- [ ] **Step 1: Create `playbooks/site.yml`**

```yaml
- name: Configure all HIL testers
  hosts: all
  gather_facts: true
  vars_files:
    - ../inventory/group_vars/vault.yml

  roles:
    - role: ../roles/common
    - role: ../roles/users
    - role: ../roles/tester-config
    - role: ../roles/github-runner
```

- [ ] **Step 2: Create `playbooks/reboot.yml`**

```yaml
- name: Reboot all testers
  hosts: all
  gather_facts: false

  tasks:
    - name: Reboot
      ansible.builtin.reboot:
        reboot_timeout: 120
      become: true
```

- [ ] **Step 3: Create `playbooks/runner-update.yml`**

```yaml
# Update the GitHub Actions runner binary on all testers (or use --limit for one).
# Usage:
#   ansible-playbook playbooks/runner-update.yml
#   ansible-playbook playbooks/runner-update.yml --limit tester-01
- name: Update GitHub Actions runner
  hosts: all
  gather_facts: false
  vars_files:
    - ../inventory/group_vars/vault.yml

  tasks:
    - name: Stop runner service
      ansible.builtin.shell: |
        cd /home/hatch-runner/actions-runner
        ./svc.sh stop
      become: true

    - name: Get new registration token
      ansible.builtin.uri:
        url: "https://api.github.com/repos/{{ github_runner_org }}/{{ github_runner_repo }}/actions/runners/registration-token"
        method: POST
        headers:
          Authorization: "Bearer {{ github_pat }}"
          Accept: "application/vnd.github+json"
        status_code: 201
      register: reg_token_response
      no_log: true

    - name: Download runner v{{ github_runner_version }}
      ansible.builtin.get_url:
        url: "https://github.com/actions/runner/releases/download/v{{ github_runner_version }}/actions-runner-linux-x64-{{ github_runner_version }}.tar.gz"
        dest: "/tmp/actions-runner.tar.gz"
        mode: '0644'
      become: true
      become_user: hatch-runner

    - name: Extract runner
      ansible.builtin.unarchive:
        src: /tmp/actions-runner.tar.gz
        dest: /home/hatch-runner/actions-runner
        remote_src: true
        owner: hatch-runner
        group: hatch-runner
      become: true

    - name: Re-configure runner
      ansible.builtin.shell: |
        sudo -u hatch-runner -H \
          /home/hatch-runner/actions-runner/config.sh \
            --url "https://github.com/{{ github_runner_org }}/{{ github_runner_repo }}" \
            --token "{{ reg_token_response.json.token }}" \
            --name "{{ inventory_hostname }}" \
            --labels "hil,tester-{{ product }},{{ capabilities | map('regex_replace', '^(.+)$', 'has-\1') | join(',') }},embedded-unit-test" \
            --unattended \
            --replace
      become: true
      no_log: true

    - name: Start runner service
      ansible.builtin.shell: |
        cd /home/hatch-runner/actions-runner
        ./svc.sh start
      become: true
```

- [ ] **Step 4: Commit**

```bash
git add playbooks/
git commit -m "feat: site, reboot, and runner-update playbooks"
```

---

### Task 9: GitHub workflows

- [ ] **Step 1: Create `.github/workflows/lint.yml`**

```yaml
name: Lint

on:
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install lint tools
        run: pip install ansible-lint yamllint

      - name: Run yamllint
        run: yamllint -d relaxed .

      - name: Run ansible-lint
        run: ansible-lint playbooks/site.yml
```

- [ ] **Step 2: Create `.github/workflows/apply.yml`**

```yaml
name: Apply Fleet Config

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  apply:
    runs-on: ansible-controller
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4

      - name: Install Ansible (if not present)
        run: |
          if ! command -v ansible-playbook &>/dev/null; then
            sudo apt-get install -qq -y ansible
          fi

      - name: Write vault password file
        run: echo "${{ secrets.ANSIBLE_VAULT_PASSWORD }}" > .vault-pass

      - name: Apply fleet config
        run: |
          ansible-playbook \
            -i inventory/hosts.yml \
            --vault-password-file .vault-pass \
            playbooks/site.yml
        env:
          ANSIBLE_SSH_PRIVATE_KEY_FILE: ~/.ssh/hil-fleet-controller
          ANSIBLE_HOST_KEY_CHECKING: "false"

      - name: Clean up vault password file
        if: always()
        run: rm -f .vault-pass
```

Note: `runs-on: ansible-controller` means you must have a self-hosted runner inside the office LAN with that label. See Task 11 for setting up the controller.

- [ ] **Step 3: Commit**

```bash
git add .github/
git commit -m "feat: apply and lint GitHub Actions workflows"
```

---

### Task 10: README

- [ ] **Step 1: Create `README.md`**

```markdown
# hil-fleet

Ansible configuration for the Hatch HIL tester fleet.

## What this repo manages

- SSH authorized keys for the `admin` account on every tester
- `/etc/hatch-tester.conf` (hardware identity: product, capabilities, serial port)
- GitHub Actions runner registration and labels

## Common operations

### Add / remove SSH access for a person

Edit `inventory/group_vars/all.yml` → `admin_authorized_keys`. Open a PR. Merge.
Changes propagate to all testers within ~5 minutes.

### Add a new tester

1. Follow the new-tester procedure in the design spec.
2. Add a block to `inventory/hosts.yml`:
   ```yaml
   tester-NN:
     ansible_host: 10.0.4.1NN
     product: restoreV5          # or: riot, riotPlus, ha25, etc.
     capabilities: [esp-prog]   # add power-relay if a PDU is attached
     unit_test_port: /dev/ttyUSB1
   ```
3. Open a PR. Merge.

### Change what hardware is attached to a tester

Edit the `product` / `capabilities` for that host in `inventory/hosts.yml`. Open a PR. Merge.

### Update runner version fleet-wide

Bump `github_runner_version` in `inventory/group_vars/all.yml`. Open a PR. Merge.

### Reboot all testers

```bash
ansible-playbook -i inventory/hosts.yml playbooks/reboot.yml
```

### Ad-hoc commands

```bash
ansible all -m ping                          # health check
ansible all -a "df -h"                       # disk usage
ansible all -a "systemctl status actions.runner.*.service"
ansible --limit tester-03 -m reboot          # reboot one tester
```

## Secrets

Three secrets; all stored via Ansible Vault (`inventory/group_vars/vault.yml`).

| Secret | Purpose |
|---|---|
| `vault_github_pat` | Fine-grained PAT on rest_plus with `Administration: write`. Used to mint runner registration tokens during label updates. Rotate every 6 months. |
| Vault password | Stored as `ANSIBLE_VAULT_PASSWORD` GitHub Actions secret on this repo. Also in LastPass. Rotate annually. |
| Ansible controller SSH private key | `~/.ssh/hil-fleet-controller` on the controller box. Its public key is the `ansible-controller` entry in `admin_authorized_keys` and is hardcoded into `configure.sh --tester`. Rotate annually — see rotation procedure below. |

### Rotating the controller key

1. Generate a new key pair: `ssh-keygen -t ed25519 -C "ansible-controller@hatch" -f ~/.ssh/hil-fleet-controller-new`
2. Add the new public key as a second entry in `admin_authorized_keys` (keep the old one too). Merge + apply (both keys are now accepted on all testers).
3. Update the hardcoded key in `dev-setup/configure.sh` to the new public key. Merge.
4. Update the private key on the controller box: `mv ~/.ssh/hil-fleet-controller-new ~/.ssh/hil-fleet-controller`.
5. Remove the old public key from `admin_authorized_keys`. Merge + apply (old key is revoked on all testers).

## Adding the `ansible-controller` runner

The `apply.yml` workflow runs on `runs-on: ansible-controller`. This is a self-hosted runner inside the office LAN that has SSH access to all testers. Set it up like any other tester (same Debian install + configure.sh + setup_runner.sh) but:
- Give it the `ansible-controller` label instead of (or in addition to) hardware labels.
- Copy `~/.ssh/hil-fleet-controller` (the private key) to its `admin` account.
- No lamp needs to be attached.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with operations guide"
```

- [ ] **Step 3: Push all commits to GitHub**

```bash
git push -u origin main
```

---

### Task 11: Set up the Ansible controller runner

The `apply.yml` workflow needs `runs-on: ansible-controller` — a self-hosted runner inside the office LAN. Use any spare machine (or co-locate on tester-01 as a second runner with the extra label).

- [ ] **Step 1: Provision the machine with configure.sh**

On the controller machine (as admin):

```bash
curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh | bash -s -- --tester
```

- [ ] **Step 2: Register the runner with the `ansible-controller` label**

In GitHub: go to `https://github.com/hatch-baby/rest_plus/settings/actions/runners/new` → copy the token.

On the controller machine:

```bash
curl -fsSL https://hatch-embedded.github.io/dev-setup/sh/setup_runner.sh \
  | sudo bash -s -- <TOKEN>
```

Then in the GitHub UI, add the `ansible-controller` label to this runner (in addition to whatever labels setup_runner.sh assigned).

- [ ] **Step 3: Copy the controller private key to the controller machine**

```bash
# From your workstation:
scp ~/.ssh/hil-fleet-controller admin@<controller-ip>:~/.ssh/hil-fleet-controller
ssh admin@<controller-ip> "chmod 600 ~/.ssh/hil-fleet-controller"
```

- [ ] **Step 4: Set the `ANSIBLE_VAULT_PASSWORD` secret on the hil-fleet repo**

In GitHub: go to `https://github.com/hatch-baby/hil-fleet/settings/secrets/actions` → New repository secret → name it `ANSIBLE_VAULT_PASSWORD` → paste the vault password.

- [ ] **Step 5: Add the controller to the hil-fleet inventory** (optional but recommended)

Add it as a host in `inventory/hosts.yml` with no product/capabilities/unit_test_port but with the `ansible-controller` label noted in a comment. This ensures its SSH keys and sshd config are also managed by Ansible.

---

### Task 12: End-to-end test of the full fleet flow

- [ ] **Step 1: Run a dry-run apply from the controller**

On the controller machine (or from your workstation if you have Ansible installed):

```bash
cd ~/path/to/hil-fleet-checkout
ansible-playbook \
  -i inventory/hosts.yml \
  --vault-password-file <(echo "$VAULT_PASSWORD") \
  --check \
  playbooks/site.yml
```

Expected: Ansible connects to tester-01, reports planned changes, exits 0. Fix any errors before proceeding.

- [ ] **Step 2: Run a real apply**

```bash
ansible-playbook \
  -i inventory/hosts.yml \
  --vault-password-file <(echo "$VAULT_PASSWORD") \
  playbooks/site.yml
```

Expected: all tasks complete, runner restarts if config changed.

- [ ] **Step 3: Verify tester-01 state**

```bash
# SSH as admin using your personal key (not password)
ssh admin@10.0.4.101

# On tester-01:
cat /etc/hatch-tester.conf
cat ~/.ssh/authorized_keys
grep PasswordAuthentication /etc/ssh/sshd_config
```

Expected:
- `/etc/hatch-tester.conf` has correct PRODUCT, CAPABILITIES, UNIT_TEST_PORT
- `authorized_keys` contains all keys from `admin_authorized_keys` (and nothing else)
- `PasswordAuthentication no`

- [ ] **Step 4: Verify runner labels in GitHub**

In GitHub: `https://github.com/hatch-baby/rest_plus/settings/actions/runners`

Expected: runner `tester-01` is Idle with labels `hil`, `tester-restoreV5` (or your product), `has-esp-prog` (etc.), `embedded-unit-test`.

- [ ] **Step 5: Trigger the apply workflow via the GitHub UI**

In GitHub: `https://github.com/hatch-baby/hil-fleet/actions/workflows/apply.yml` → Run workflow.

Expected: workflow runs on `ansible-controller`, applies config, exits green.

---

## Self-review

Spec coverage check:

| Spec requirement | Covered by |
|---|---|
| `configure.sh --tester` creates admin + hatch-runner | Task 2 |
| Bootstrap key in admin's authorized_keys | Task 2 (install_bootstrap_key) |
| PermitRootLogin no | Task 2 (harden_sshd_tester) |
| PasswordAuthentication disabled after Ansible | Task 6 (common role) |
| `setup_runner.sh` installs runner + ESP-IDF | Task 3 |
| Runner registered without labels initially | Task 3 (config.sh has no --labels arg) |
| `inventory/hosts.yml` per-host product/capabilities | Task 5 |
| `inventory/group_vars/all.yml` SSH key whitelist | Task 5 |
| Ansible Vault for secrets | Task 5 (vault.yml) |
| authorized_keys replaced on apply | Task 6 (users role) |
| /etc/hatch-tester.conf written by Ansible | Task 7 (tester-config role) |
| Runner re-registered with steady-state labels on apply | Task 7 (github-runner role) |
| UNIT_TEST_PORT set in runner .env | Task 7 (github-runner role) |
| apply.yml runs on ansible-controller | Task 9 |
| lint.yml on PRs | Task 9 |
| Ansible controller key is the bootstrap key | Tasks 1+6 (same key pair) |
| Fleet ops (reboot, runner update) | Tasks 8 (reboot.yml, runner-update.yml) |
| README with ops guide | Task 10 |
