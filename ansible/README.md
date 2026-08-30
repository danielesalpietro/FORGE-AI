# `ansible/`

17 roles, 15 playbooks, 21 templates, and an inventory that is derived
rather than restated.

```text
ansible/
├── ansible.cfg              run every command from this directory
├── requirements.yml         collections, pinned with >=,<
├── inventories/poc/         the dynamic inventory and group vars
├── playbooks/               one per stage, plus site.yml
├── roles/                   17, each with a README
├── templates/               21, rendered under StrictUndefined
└── filter_plugins/          the filters those templates depend on
```

## The inventory is derived, not written

`inventories/poc/forge-inventory.py` reads `config/poc.yml` — through
the same loader the validator and the tests use — and produces the host
list, the groups and every connection variable.

A static inventory would restate every IP address, MAC address and
connection setting that already exists in the configuration. The two
would drift, and **drift in an inventory is how a playbook configures
the wrong machine.**

It **refuses to build** from a configuration that does not validate.
With `any_unparsed_is_failed` in `ansible.cfg`, that means an invalid
desired state stops the run at parse time.

Two config keys are renamed on the way in, because Ansible reserves them
as play keywords: `hosts` → `forge_hosts`, and `environment` →
`deployment` (renamed in the configuration itself).

## Playbooks

| Playbook | Stage |
|---|---|
| `validate-prerequisites.yml` | Read-only host checks |
| `bootstrap-control-plane.yml` | Host packages, network, Compose, Gitea, Semaphore |
| `create-provisioning-network.yml` | The isolated libvirt network |
| `deploy-pxe-stack.yml` | dnsmasq, iPXE scripts, host registry |
| `prepare-ubuntu-media.yml` | Download, verify, unpack, render the seed |
| `prepare-windows-media.yml` | Validate the ISO, inspect the WIM, build WinPE |
| `create-vms.yml` | Define and start the domains |
| `provision-ubuntu.yml` | Boot, install, wait for SSH, purge the seed |
| `provision-windows.yml` | Boot, install, wait for WinRM, purge the answer file |
| `configure-targets.yml` | The baselines — **also what drift runs in check mode** |
| `validate-deployment.yml` | Validation, idempotence check, report |
| `detect-drift.yml` | Check mode plus compliance probes. Changes nothing. |
| `reconcile.yml` | Reapply, then re-detect and fail if drift survives |
| `destroy-poc.yml` | Guarded teardown |
| `site.yml` | All of the above, in order |

Every stage is standalone, so a failure is resumed from where it failed.

## Roles

Each has a `README.md` explaining what it does **and why the
non-obvious parts are that way**.

| Role | Notable for |
|---|---|
| `prerequisite_validation` | Accumulates findings and reports them together; the passive DHCP probe |
| `libvirt_host` | The state directory is owned by UID 10001 — the container's unprivileged user |
| `libvirt_network` | Fails if libvirt started its own dnsmasq |
| `pxe_server` | A dedicated dnsmasq instance; config validated before any restart |
| `ipxe_menu` | Writes the registry, then proves the dispatch path answers |
| `ubuntu_media` | Checksum policy: pinned wins, otherwise the official `SHA256SUMS` |
| `ubuntu_autoinstall` | Asserts the hash format and that an SSH key exists, before rendering |
| `windows_media` | **Fails with the available edition list** rather than guessing |
| `windows_winpe` | Injects VirtIO drivers on Linux; finds the Setup image by name |
| `windows_unattend` | Greps the rendered file for the cleartext password |
| `vm_lifecycle` | Boot order as the second half of the loop guard |
| `ubuntu_baseline` | Written to be check-mode safe; ordering that avoids lockout |
| `windows_baseline` | TLS 1.2 enabled *before* older versions are disabled |
| `gitea_config` | Prints the branch-protection steps rather than guessing the API |
| `semaphore_config` | Prints what remains manual rather than implying it happened |
| `drift_detection` | Labels every finding with its source; records blind spots |
| `reporting` | Reads cacheable facts, so it can describe a failed run |

## Tags

```bash
ansible-playbook playbooks/site.yml --tags security
ansible-playbook playbooks/site.yml --skip-tags windows
```

`bootstrap` · `provisioning` · `network` · `media` · `linux` ·
`windows` · `security` · `validation` · `drift` · `reporting` ·
`destroy`

## Configuration

`ansible.cfg` notes two things worth knowing:

- There is deliberately **no** `error_on_undefined_vars` line. Erroring
  on an undefined variable has been the default for years, and
  ansible-core 2.19 deprecated the option — setting it emits a warning
  on every run and buys nothing.
- `ansible-config validate` reports `[ssh_connection]` as an unknown
  section. That is a limitation of that subcommand; the settings are
  genuinely applied, and the file says how to confirm it.

## Running

```bash
cd ansible
ansible-playbook playbooks/site.yml --vault-password-file ../.vault-password
ansible-inventory --list --yaml
ansible all -m ping
ansible-lint --offline
```

Or from the repository root: `make deploy`, `make configure`,
`make inventory`.
