# Limitations

What this proof of concept deliberately does not do, what it cannot do,
and where the line between the two falls.

> A PoC that overstates its coverage is worse than one that is explicit
> about the gaps. Everything below is a **known** trade-off, chosen and
> recorded — not something waiting to be discovered.

---

## Scope

### It is a proof of concept

Two virtual machines on one host. It demonstrates the full lifecycle —
commit to running, configured, verified machines — but it is not sized,
hardened or operated as a production provisioning platform. The specific
gaps are below.

### Two hosts, one hypervisor

The configuration model supports up to 32 hosts and the code has no
per-host special cases, but nothing here has been exercised beyond two,
and several things would need attention at scale:

- One dnsmasq instance and one boot server, both single points of
  failure.
- Semaphore is configured with `max_parallel_tasks: 1`.
- No hypervisor scheduling: `config/poc.yml` names the host implicitly
  by being on it.

### No multi-site, no HA

One control plane, one provisioning network, no failover. Gitea and
Semaphore have no replication and their volumes have no backup
configured.

---

## Media and licensing

### Windows Server media is yours to supply

**No Microsoft binary is in this repository** — no ISO, no `boot.wim`,
no `install.wim`, no ADK component, no product key. The operator
downloads Windows Server Evaluation media themselves and accepts
Microsoft's licensing terms.

`docs/WINDOWS-PROVISIONING.md` explains how. The Ubuntu target deploys
without any of it.

### Activation is out of scope

Nothing here activates Windows. Evaluation media installs unkeyed and
runs for its evaluation period. Managing licences, KMS or MAK keys is
deliberately not automated: it is a licensing decision, not a technical
one, and automating it would invite an accident.

### WinPE optional components need the Windows ADK

`scripts/build-winpe.sh` injects VirtIO drivers into `boot.wim` using
`wimlib-imagex` on Linux — no Windows machine required.

It **cannot** add WinPE optional components: PowerShell, WMI, .NET.
Those need the ADK on a Windows workstation. Nothing in this PoC needs
them — `startnet.cmd` is plain batch precisely so that it does not — but
if you customise the WinPE stage you may.

`media.windows.winpe_source: prebuilt` accepts an externally built image;
`docs/WINDOWS-PROVISIONING.md` has the ADK procedure.

---

## Security

Every item here is expanded, with its production alternative, in
[SECURITY.md](SECURITY.md).

### Secure Boot is off

The distribution's `ipxe.efi` is not signed by a key in the default OVMF
`db`, and neither is the Ubuntu kernel as chained by iPXE. The domains
are defined with `<feature enabled="no" name="secure-boot"/>`.

### Answer files carry credentials, briefly

An unattended installer must authenticate before any secret store
exists. The Ubuntu seed carries a **crypt(3) hash**; `Autounattend.xml`
carries a **reversible** Base64(UTF-16LE) encoding of the administrator
password.

Both are served only on the isolated provisioning network, the Windows
answer file never touches the SMB share, and both are purged once the
host reports `installed`. The exposure window is real and is recorded in
a `PURGED.txt` on the host.

### WinRM certificate validation is off by default

The certificate is generated self-signed during the Windows specialize
phase, so there is nothing for the runner to trust yet.
`security.winrm_cert_validation` is a single named switch, every tool
that honours it says so when it runs, and CI fails if any script
disables TLS validation *without* such a control. It is loud, but the
default is `ignore`.

### One shared local administrator password

No domain, so no Kerberos, so a shared static credential in the vault.
`windows_baseline` reports Windows LAPS readiness — module present,
domain joined — so the gap is visible, but LAPS needs a directory to
store the rotated password and a workgroup host has none.

### The boot server does not authenticate reads

A PXE ROM has no credential to present. Anything on the provisioning
bridge can read every boot artefact. Mutating state endpoints require a
shared token; GET cannot.

### Media integrity is checked, signatures are not

The Ubuntu ISO's SHA-256 is verified against the official `SHA256SUMS`,
but **the GPG signature on that file is not checked**. An attacker able
to substitute both over HTTPS would defeat it. Windows media has no
publisher checksum at all — only the operator's own pin.

### Secrets are long-lived

Vault and Key Store entries do not rotate. There is no just-in-time
issuance and no per-task scoping. Rotation procedures are documented and
manual.

---

## Drift detection

### Ansible check mode is not complete, and this is not hidden

Check mode's accuracy depends on each module implementing it. In
particular:

| Module | Check-mode support |
|---|---|
| `ansible.windows.win_shell` | **None** — skipped entirely |
| `ansible.windows.win_command` | **None** |
| `ansible.windows.win_updates` | **None** |
| `community.windows.win_security_policy` | Partial |
| `ansible.builtin.command` / `shell` | None; `changed_when: false` hides them |

A check-mode-only report would be silently blind to SMBv1, the firewall
defaults, the PowerShell execution policy and the event log sizing.

**This is why every control has a matching read-only compliance probe.**
The drift report labels each finding with its source and records its
blind spots in `check_mode_unsupported`. It does not claim coverage the
modules do not provide.

### The probes are narrow

They cover what someone wrote a probe for — currently five on Linux and
seven on Windows. A change outside that set is invisible to them.
Adding one is a few lines in
`ansible/inventories/poc/group_vars/{linux,windows}/main.yml`.

### Detection is not continuous

Drift is found when the workflow runs, not when it happens. There is no
agent and no file-integrity monitoring. A scheduled Semaphore task is
the closest this gets.

### Reconciliation is manual by design

`drift.auto_reconcile` is `false`, and scheduled reconciliation is
opt-in. That is a deliberate position, not a missing feature: automatic
reconciliation erases the evidence of what changed, and a change that
*should* persist belongs in Git rather than being reverted.

---

## Testing

### CI cannot deploy anything

GitHub-hosted runners have no nested virtualisation. Everything CI runs
is validation: schema, semantics, template rendering, XML and YAML
parsing, Ansible syntax, unit tests, secret hygiene, container scanning.

**No VM is created and no operating system is installed in CI.**

`.github/workflows/e2e-selfhosted.yml` is the full end-to-end path. It
is **disabled rather than deleted**, so the procedure stays in version
control and this claim stays checkable. Enabling it needs a self-hosted
runner with `/dev/kvm`, 32 GB of RAM and the operator's Windows media on
the runner.

### Molecule tests a container, not a machine

The `ubuntu_baseline` scenario runs against a systemd container. Its
`idempotence` step is genuinely valuable — it is the property the drift
report depends on. But a container cannot verify:

- **ufw** — a container shares the host netfilter tables, so enabling a
  default-deny policy inside one is either a no-op or a very bad idea;
- **qemu-guest-agent** — there is no virtio-serial channel;
- **reboot handling**.

Those are covered by `scripts/smoke-test.sh` against a real VM. A green
Molecule run is not the same as a working host, and the scenario says so
in its own header.

### The Windows path has less automated coverage

`Autounattend.xml` is parsed and checked pass by pass, the password
encoding is round-tripped, and the WIM edition is validated before any
installation. But the *behaviour* of Windows Setup, `SetupComplete.cmd`
and `Configure-WinRM.ps1` can only be verified by running them.

### No performance or load testing

Nothing measures how long a deployment takes under contention, or what
happens with ten simultaneous installations.

---

## Operations

### No backup or restore

The Docker volumes holding Gitea repositories and the Semaphore audit
trail are not backed up. `make destroy-all --volumes` destroys them
permanently, which is why `--volumes` is a separate flag.

### No monitoring or alerting

The deployment report is a point-in-time record. There is no metrics
endpoint, no log shipping, and no alert when a host reaches its install
attempt limit — you find out by running `make state`.

### Logs stay on the host

dnsmasq, nginx, guest installer uploads, Ansible, Semaphore history and
QEMU logs all live on the KVM host. Nothing is shipped anywhere, and
nothing is rotated beyond Docker's own 10 MB × 5 file cap on container
logs.

### Semaphore setup is not fully automated

The role creates the project, key store entries, repository, inventory,
environment and all thirteen templates through the API. Two things
remain manual, and the role **prints** them rather than implying they
happened:

- **Schedules** — add a drift-check schedule in the UI if you want one.
- **Gitea branch protection** — the payload shape has moved between
  Gitea releases, and a silently-wrong call leaves the branch
  unprotected, which is worse than not trying. The exact UI steps are
  printed instead.

---

## Platform

### Ubuntu 24.04 LTS x86_64 only

Validated nowhere else. Other distributions would need different package
names, a different OVMF path and a different dnsmasq unit layout. Other
architectures would need different iPXE binaries and different Windows
media entirely.

`docs/COMPATIBILITY.md` records exactly what was tested.

### UEFI is the tested path

Both targets default to UEFI. Legacy BIOS support exists — dnsmasq
serves `undionly.kpxe` for `client-arch 0` — and is documented, but it
is not the path this PoC exercises.

### IPv4 only

No IPv6 addressing, no DHCPv6, no IPv6 PXE.

### No cloud or bare-metal targets

libvirt/KVM only. There is no vSphere, Proxmox, cloud or physical
bare-metal path. Redfish-based bare-metal provisioning would be a
natural extension — the boot chain is already the hard part — but it is
not here.

---

## Where a claim is qualified

If something in this repository reads as a stronger claim than the code
supports, that is a defect and worth reporting. The places where
language was deliberately softened:

| Claim | Qualification |
|---|---|
| "CIS-inspired" controls | **Not** a CIS benchmark run. A handful of settings, informed by the benchmark. The role says so in its own output. |
| "Idempotent" | Verified by Molecule and by a second check-mode run. Not proven for every module in every state. |
| "Drift detection" | Two sources, both with stated limits. Not complete coverage. |
| "Zero-touch" | After the operator supplies media, configures the network and runs bootstrap. The *provisioning* is zero-touch. |
| "Production-oriented" | Written in a production idiom — validation, error handling, least privilege — but with the residual risks above. |

---

## Roadmap

Roughly in order of value:

1. **Domain join and Kerberos** — removes the shared local
   administrator, the largest residual risk.
2. **Windows LAPS**, once a directory exists.
3. **Secure Boot** with signed boot components.
4. **Backup and restore** for the Gitea and Semaphore volumes.
5. **Log shipping** and alerting on install-attempt exhaustion.
6. **More compliance probes**, particularly on Windows.
7. **Bare-metal targets** over Redfish.
8. **A second hypervisor backend.**
9. **GPG signature verification** on `SHA256SUMS`.
10. **Ephemeral runners** and just-in-time secrets.
