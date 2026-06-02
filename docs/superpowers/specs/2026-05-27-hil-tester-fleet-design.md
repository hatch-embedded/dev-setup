# HIL Tester Fleet — Design

**Status:** Draft for review
**Owner:** Nash Witkin (nash.witkin@hatch.co)
**Date:** 2026-05-27

## Goal

Provision and operate a fleet of ~10 Mini-PC machines as Hardware-in-the-Loop (HIL) testers for Hatch embedded firmware. Each tester runs a GitHub Actions self-hosted runner and has a Hatch lamp (Restore-family or Riot-family) physically attached via USB. The fleet supports automated unit tests today and HIL tests in the near future.

## Non-goals

- Replacing the firmware build / unit-test logic itself. The existing `tools/unit_test.sh` and `tools/setup/setup.sh` in `rest_plus` stay as-is.
- Choosing a CI trigger pattern (PR / merge / nightly). The setup supports all three; the trigger decision is made later based on observed test duration.
- Power control / remote hard reset of wedged testers. Called out as future work.
- PXE / netboot. Manual Debian install per machine stays. Not worth the infrastructure at 10 testers.

## Background

The current state of the world:

- `hatch-embedded/dev-setup` (private; `configure.sh` served publicly via GitHub Pages) provisions developer machines and, with `--skip-git`, tester machines too. It creates *the install-time user* — not a dedicated service account.
- `hatch-baby/rest_plus` contains the firmware and a build-deps installer at `tools/setup/setup.sh`.
- A single tester exists today. The provisioning procedure in `rest_plus/doc/tester_setup.md` is fully manual: register the runner by hand, configure labels by hand, set `UNIT_TEST_PORT` by hand.
- There is no fleet-wide mechanism for managing SSH keys, runner versions, or per-host hardware identity. Scaling to 10 testers without one means per-machine drudgery whenever anything changes.

## Decisions

| Topic | Decision | Rationale |
|---|---|---|
| Network | Testers live on the Hatch office LAN. Humans reach them via Hatch VPN. | Already the existing topology. No new infra. |
| Fleet config tool | **Ansible** (open-source core; `apt install ansible`). | Industry-standard for fleet config management at this scale. One-time learning cost; gives reusable fleet ops beyond SSH keys. |
| User accounts on each tester | **`admin`** (human SSH, sudo) + **`hatch-runner`** (locked-down service account, runs the GitHub Actions runner). | Cleaner separation than a single account; small extra setup cost worth it. |
| Hardware identity | Layered GitHub Actions runner labels driven by a per-host config file `/etc/hatch-tester.conf`. | Multiple labels per runner match the granularity needed (`hil`, `tester-<product>`, `has-<capability>`). Workflows target the specific combination they need. |
| Source of truth | New private repo **`hatch-baby/hil-fleet`** holds Ansible inventory, playbooks, and the SSH-key whitelist. | Separate repo from `embedded-support` keeps blast radius isolated, gates inventory changes on different reviewers if needed, separates apply-on-merge CI from script CI. Standard pattern for infrastructure-as-code. |
| Bootstrap | Manual Debian install + one curl of `configure.sh --tester`. After that, Ansible adopts the machine. | Physical install is unavoidable; everything after it is automated via Ansible inventory PRs. |
| Build-deps install | `setup_runner.sh` clones `rest_plus` and calls `tools/setup/setup.sh` directly. No GitHub workflow involved. | Operator is already SSHed in; running the script directly is simpler than a workflow round-trip. Build deps still live in `rest_plus` next to the firmware that requires them. |
| CI trigger pattern | Deferred. Runner setup is identical regardless. | TBD based on test duration once HIL tests exist. |

## Repo split

Three repos, each with a clear job:

### `hatch-embedded/dev-setup` (existing, private; pages public)

Owns OS-level base configuration. The work in this repo:

- Extend `configure.sh` with a `--tester` mode (supersedes `--skip-git`). In tester mode the script:
  - Treats the install-time user (named `admin` during Debian install) as the human ops account. Ensures it has NOPASSWD sudo.
  - Creates `hatch-runner` user (locked down: no password set, login shell `/bin/bash` but `PasswordAuthentication no` plus no key in `authorized_keys` means no remote SSH login). Adds `hatch-runner` to `dialout` and `docker` groups. Writes `/etc/sudoers.d/hatch-runner` granting only what the runner needs — narrow allowlist of `apt-get`, `systemctl restart actions.runner.*`, and access to `/dev/ttyUSB*` via group membership.
  - Drops a single **bootstrap public key** into `admin`'s `authorized_keys`, alongside whatever key the operator added during install. The bootstrap key is held only by the Ansible controller / apply workflow's secret store. Humans get their personal keys later, via Ansible.
  - Sets `PermitRootLogin no` in `sshd_config` and restarts sshd. Leaves `PasswordAuthentication` **on** for now — Ansible disables it on first apply, once the human key whitelist is in place. This avoids locking the operator out between configure.sh and the first Ansible run.
  - Skips the personal-git-identity prompts (existing `--skip-git` behavior).
  - Does **not** install ESP-IDF or other build deps. Those are handled by `setup_runner.sh`.
- Add a new helper script `sh/setup_runner.sh`. The operator runs it once per new tester with a registration token fetched from the GitHub UI:
  ```
  curl -fsSL https://hatch-embedded.github.io/dev-setup/sh/setup_runner.sh \
    | sudo bash -s -- <REGISTRATION-TOKEN>
  ```
  The script:
  - Pins the GitHub Actions runner version (a variable at the top — bump by editing dev-setup).
  - Switches to `hatch-runner` and: creates `~/actions-runner`, downloads + extracts the pinned runner tarball, runs `config.sh --url https://github.com/hatch-baby/rest_plus --token <TOKEN> --unattended`.
  - Back as root: runs `svc.sh install hatch-runner` and `svc.sh start`.
  - Clones `rest_plus` into `~hatch-runner/git/rest_plus` and runs `tools/setup/setup.sh` to install ESP-IDF and build deps.
  - Idempotent: skips runner config if already configured, skips clone if repo already exists.

### `hatch-baby/rest_plus` (existing, private)

Unchanged structurally. Continues to own:

- Firmware build deps installer at `tools/setup/setup.sh` (called by `setup_runner.sh` during initial provisioning).
- Existing unit-test workflow at `.github/workflows/unit-test.yml`. Later, workflows that target hardware-specific tests will use `runs-on: [hil, tester-<product>]` matrix entries.

### `hatch-baby/hil-fleet` (NEW, private)

Owns fleet-wide config and operational tooling. Initial layout:

```
hil-fleet/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml                  # per-host facts
│   └── group_vars/
│       └── all.yml                # SSH key whitelist, shared vars
├── playbooks/
│   ├── site.yml                   # top-level; runs all roles
│   ├── reboot.yml                 # ad-hoc fleet ops
│   └── runner-update.yml          # bump runner version
├── roles/
│   ├── common/                    # base packages, ssh hardening
│   ├── users/                     # admin authorized_keys, hatch-runner config
│   ├── tester-config/             # writes /etc/hatch-tester.conf
│   └── github-runner/             # installs runner, registers with steady-state labels
├── README.md
└── .github/
    └── workflows/
        ├── apply.yml              # runs ansible-playbook on merge to main
        └── lint.yml               # ansible-lint + yamllint on PRs
```

`inventory/hosts.yml` schema (illustrative):

```yaml
all:
  hosts:
    tester-01:
      ansible_host: 10.0.4.101
      product: restoreV5
      capabilities: [esp-prog, power-relay]
      unit_test_port: /dev/ttyUSB1
    tester-02:
      ansible_host: 10.0.4.102
      product: riot
      capabilities: [esp-prog]
      unit_test_port: /dev/ttyUSB1
    # ...
```

`inventory/group_vars/all.yml` (illustrative):

```yaml
admin_authorized_keys:
  - name: nash
    key: "ssh-ed25519 AAAA... nash@hatch.co"
  - name: someone-else
    key: "ssh-ed25519 AAAA... them@hatch.co"

github_runner_version: "2.319.1"
github_runner_org: hatch-baby
github_runner_repo: rest_plus
```

## On-tester filesystem (final state)

```
/etc/hatch-tester.conf
  HOSTNAME=tester-04
  PRODUCT=restoreV5
  CAPABILITIES=esp-prog,power-relay
  UNIT_TEST_PORT=/dev/ttyUSB1

/home/admin/
  .ssh/authorized_keys           # managed by Ansible from inventory/group_vars/all.yml

/home/hatch-runner/
  actions-runner/                # GitHub Actions runner
    .env                         # contains UNIT_TEST_PORT (sourced from /etc/hatch-tester.conf)
    runsvc.sh                    # systemd-managed

/etc/sudoers.d/admin             # %admin ALL=(ALL) NOPASSWD: ALL
/etc/sudoers.d/hatch-runner      # narrow: apt-get, systemctl restart actions.runner.*
/etc/ssh/sshd_config             # PasswordAuthentication no, PermitRootLogin no
```

## Naming and identity conventions

- **Hostname.** `tester-NN` (zero-padded, two digits). Set during Debian install. Pinned in office DNS or `/etc/hosts` on the Ansible controller.
- **DHCP.** Every tester has a static lease in the office router pinning IP → MAC. Documented as a checklist item in the new-tester procedure.
- **Runner labels (steady-state).**
  - `hil` — every HIL tester.
  - `tester-<product>` — one per product (e.g. `tester-restoreV5`, `tester-riot`).
  - `has-<capability>` — one per capability (e.g. `has-esp-prog`, `has-power-relay`).
  - `embedded-unit-test` — kept for backward compatibility with the existing workflow.
- **Runner labels (transient).** None. The initial `setup_runner.sh` registers the runner without labels; Ansible assigns the steady-state label set on first apply.

## End-to-end flows

### Adding a new tester (steady-state procedure)

```
1. Image USB stick with Debian netinst. Install Debian on the
   Mini-PC. During install:
     - Set hostname `tester-NN`.
     - Set username `admin` (this is the human ops account
       used permanently — not throwaway).
     - Record admin password + root password in shared
       password manager.                                                [~20 min]

2. SSH in as admin with install-time password. Run:

     curl -fsSL https://hatch-embedded.github.io/dev-setup/configure.sh \
       | bash -s -- --tester

   - Ensures admin has NOPASSWD sudo.
   - Creates hatch-runner service account (locked down, no
     remote SSH login, narrow sudo).
   - Drops Ansible bootstrap key into admin's authorized_keys.
   - Disables root SSH; password auth remains on (Ansible
     disables it on first apply).                                       [~10 min]

3. Assign a static DHCP lease in the office router (IP → MAC).
   Add a /etc/hosts entry on the Ansible controller (or update
   office DNS) mapping tester-NN to its IP.                             [~2 min]

4. In the rest_plus GitHub UI: Settings → Actions → Runners →
   New self-hosted runner → Linux/x64. Copy the registration
   token from the page (everything after `--token` in the
   provided command).

   Still SSHed in as admin, run the helper script with that
   token:

     curl -fsSL https://hatch-embedded.github.io/dev-setup/sh/setup_runner.sh \
       | sudo bash -s -- <REGISTRATION-TOKEN>

   This installs the runner under hatch-runner, starts the
   systemd service, clones rest_plus, and runs
   tools/setup/setup.sh to install ESP-IDF and build deps.
   (~20–30 min unattended.)                                             [~30 min]

5. Open a PR against hil-fleet:
     - Add a tester-NN block to inventory/hosts.yml with product,
       capabilities, unit_test_port.
   Merge.                                                               [~2 min]

6. The apply.yml workflow runs `ansible-playbook site.yml`. It
   reaches tester-NN over SSH as admin using the Ansible
   controller's key (pre-seeded as the bootstrap key), and:
     - Replaces admin's authorized_keys with the full whitelist
       from inventory/group_vars/all.yml. The whitelist includes
       the controller's key as a permanent entry, so future
       applies keep working.
     - Sets PasswordAuthentication no and restarts sshd.
     - Writes /etc/hatch-tester.conf.
     - Registers the runner with steady-state labels
       (hil, tester-<product>, has-<capability>..., embedded-unit-test)
       via `config.sh --replace` or the GitHub API.
     - Writes UNIT_TEST_PORT into the runner's .env from
       /etc/hatch-tester.conf.
     - Ensures the runner systemd service is enabled and healthy.       [~5 min]

7. Verify the runner appears as Idle in GitHub with the expected
   label set, and that SSH as admin with your personal key works.      [~1 min]
```

Note on the bootstrap-key lifecycle: the "bootstrap key" and the "Ansible controller's key" are the same key. It's listed in `inventory/group_vars/all.yml` as a permanent entry in `admin_authorized_keys` (typically with a name like `ansible-controller`), so every Ansible apply leaves it in place. `configure.sh --tester` pre-seeds the same public key into `admin/authorized_keys` so the *first* apply has a way in before the tester is in the inventory. To re-adopt a wiped-and-reimaged tester, re-run configure.sh and the controller can reach it again on the next apply.

Total wall-clock: roughly an hour, of which ~45 minutes is unattended waiting (Debian install + setup_runner.sh building ESP-IDF). Human attention required: ~15 minutes.

### Adding or removing a human's SSH access

1. PR against `hil-fleet/inventory/group_vars/all.yml` editing `admin_authorized_keys`.
2. Merge. Apply workflow runs against the full fleet. Change propagates within ~5 minutes.

### Changing what hardware is attached to a tester

1. Physically swap the lamp on the tester.
2. PR against `hil-fleet/inventory/hosts.yml` editing the `product` / `capabilities` for that host.
3. Merge. Apply workflow re-registers the runner with the new labels.

### Updating the GitHub Actions runner version fleet-wide

1. Bump `github_runner_version` in `inventory/group_vars/all.yml`.
2. Merge. Apply workflow upgrades the runner on every box in sequence (or in small batches).

### Ad-hoc fleet operations

Run from a workstation on the VPN:

```
ansible -i inventory all -m reboot                # reboot all
ansible -i inventory tester-04 -a "df -h"         # disk usage on one box
ansible -i inventory all -m ping                  # health check
ansible-playbook -i inventory playbooks/runner-update.yml --limit tester-05
```

## Apply workflow

`hil-fleet/.github/workflows/apply.yml` runs on merge to `main`:

- Triggered by push to `main` (or `workflow_dispatch` for manual re-runs).
- `runs-on: ansible-controller` — a dedicated runner inside the office LAN. This can be one of the testers (e.g. tester-01 carries an extra `ansible-controller` label), or a separate small box. Spec defers the choice to implementation; recommendation is to use a separate box so an Ansible apply does not get blocked by a long-running test on the same machine.
- Steps: checkout, decrypt vaulted secrets, `ansible-playbook -i inventory playbooks/site.yml`.
- On failure, posts to a Slack channel (or fails the workflow visibly; Slack integration is optional polish).

The apply workflow has read access to the GitHub PAT used for runner registration (see Secrets below).

## Secrets

Three secrets are needed; all stored via **Ansible Vault** in the `hil-fleet` repo (encrypted at rest in git) and decrypted at apply time using a vault password held as a GitHub Actions secret on the `hil-fleet` repo.

| Secret | Purpose | Rotation |
|---|---|---|
| Ansible controller SSH private key | Decoded into the apply runner's SSH agent. Lets Ansible reach all testers as `admin` — both freshly-bootstrapped (where the public half is pre-seeded by `configure.sh --tester`) and steady-state (where the public half is one of the entries in the whitelist). | Rotate annually. Rotation: add the new public key to the whitelist, run apply (so all steady-state testers accept both old and new keys), update the baked-in key in configure.sh + the apply workflow's private-key secret, run apply again to drop the old key. |
| GitHub PAT (fine-grained, scoped to `hatch-baby/rest_plus`, with `Administration: write` for runner registration tokens) | Lets Ansible fetch fresh registration tokens via the GitHub API when re-registering a runner. | Rotate every 6 months. |
| Ansible Vault password | Decrypts vaulted content during apply. | Rotate annually. |

Vault password is stored as a GitHub Actions secret on `hil-fleet` (`ANSIBLE_VAULT_PASSWORD`). The other two are inside the vault.

## Open implementation choices

These are decisions we explicitly defer to the implementation plan, not blockers for this design:

1. **Ansible controller location.** Dedicated small box vs. co-located on tester-01. Recommendation: separate box (cheap, decouples apply from test load), but co-location is acceptable for v1.
2. **Runner registration mechanism.** Ansible can either (a) use the GitHub API directly via `uri` module + a PAT, or (b) shell out to `gh api`. Both work; pick whichever the playbook author finds cleaner.
3. **DNS vs. /etc/hosts on the controller.** `/etc/hosts` is fine for v1. Promote to office DNS if/when the fleet grows past ~20 boxes.
4. **Slack notifications on apply failures.** Nice-to-have polish; not required for v1.

## Future work (out of scope for v1)

- **Networked PDU for remote power control.** Each tester gets a Tasmota smart plug (or similar) on its power input. A capability label `has-pdu` plus a small CLI lets a workflow hard-reset a wedged tester. Standard pattern; defer until first time a tester wedges in a way that blocks CI.
- **PXE / netboot.** Removes the manual Debian install. Worth it past ~30 testers.
- **Org-level runners.** If multiple repos start needing the fleet, promote runners from repo-level (`rest_plus`) to org-level (`hatch-baby`). Mostly a one-line change in the registration script.
- **Auto-detect `UNIT_TEST_PORT`.** Today it's a per-host value in inventory. Could be auto-discovered by udev rules matching the ESP Prog's USB serial. Cuts one field from inventory.
- **HIL test framework.** Beyond unit tests, real HIL tests will need a way to drive lamp buttons, capture audio output, etc. Out of scope here; lives in `embedded-support`.

## Risks and trade-offs

- **Single-controller failure mode.** If the Ansible controller is unreachable, the apply workflow stalls. Inventory PRs queue up but the fleet stays at last-known-good state. Acceptable: SSH still works for humans on the VPN. Mitigation: any laptop with the vault password can run `ansible-playbook` locally to apply changes.
- **Controller-key blast radius.** The Ansible controller's key authenticates as `admin` (NOPASSWD sudo) on every tester. Compromise of that key = full fleet compromise. Mitigation: store the private half only in the apply workflow's secret store and (encrypted) on the controller; restrict the public key's `authorized_keys` line with `from="<office-LAN-CIDR>"` so it only works from inside the network; rotate annually using the procedure documented in Secrets.
- **Ansible learning curve.** Team has to learn enough YAML/Ansible to read playbooks. One-time cost; offset by the fleet ops Ansible unlocks.
- **PAT scope.** The PAT used for runner re-registration has admin-write on the repo. Treat it like a deploy key — rotate, audit, store only in the vault.

## Success criteria

- Provisioning a new tester takes <1 hour of wall-clock and <15 minutes of human attention.
- Adding or removing a human's SSH access is a single PR against `hil-fleet`, propagating fleet-wide in <10 minutes.
- Re-labeling a tester for new hardware is a single PR against `hil-fleet`.
- Running an ad-hoc command across all 10 testers is a single `ansible` command from a laptop on the VPN.
- No tester drift: any divergence from inventory is corrected on the next apply.
