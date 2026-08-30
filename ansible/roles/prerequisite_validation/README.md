# `prerequisite_validation`

Read-only checks that run before anything is created. The role never
changes the host; its only output is a list of findings and, unless
`prereq_report_only` is true, a hard failure when any of them is an
error.

## What it checks

| Check | Severity | Why |
|---|---|---|
| Ubuntu 24.04 x86_64 | error | The only validated control host (docs/COMPATIBILITY.md) |
| sudo / root | error | libvirt, dnsmasq and `/srv` all need it |
| `vmx`/`svm` CPU flag | error | Without it KVM falls back to emulation and Windows Setup takes hours |
| `/dev/kvm` present and writable | error | The usual cause is missing `kvm`/`libvirt` group membership |
| RAM ≥ sum of target RAM + 4 GB | error | Computed from `config/poc.yml`, not a fixed number |
| Free disk ≥ sum of target disks + 60 GB | error | qcow2 images plus extracted media |
| CPU cores | warning | Installs still work, slowly |
| Required commands on `PATH` | error | Points at `bootstrap/prepare-host.sh` |
| `virsh --connect qemu:///system` | error | libvirtd not running is the common case |
| OVMF firmware present | error | Only when a host requests UEFI |
| Competing DHCP server | error | See below |
| Control-plane ports free | warning | A previous run holding them is expected |
| Ubuntu ISO present | warning | `make prepare-media` fixes it |
| Windows ISO present | warning | Operator-supplied; Ubuntu-only runs are unaffected |

## The DHCP probe

`tasks/dhcp-conflict.yml` listens passively on the provisioning bridge
for DHCP traffic. It never sends a DISCOVER — broadcasting onto a
network we have not been cleared to touch would itself be the problem
we are trying to avoid.

On a first run the bridge does not exist yet, and the probe says so
rather than reporting a clean result it could not have measured. Re-run
`make check` after the control plane is up for a real measurement.

Disable with `safety.abort_on_dhcp_conflict: false` in `config/poc.yml`,
or override a specific finding with `-e forge_force=true`.

## Usage

```bash
make check                                  # report-only
cd ansible && ansible-playbook playbooks/validate-prerequisites.yml
```

## Outputs

`forge_prereq_result` (cacheable fact):

```yaml
forge_prereq_result:
  checked_at: "2026-08-27T09:12:44Z"
  status: pass          # or fail
  findings:
    - severity: warning
      check: windows-media
      detail: "media.windows.iso_path is empty ..."
```

The `reporting` role folds this into the deployment report.
