# `ubuntu_baseline`

Desired state for the Ubuntu target: identity, packages, SSH, firewall,
time, audit and a health command.

## Written to be run in check mode

This same role is what `detect-drift.yml` runs with `--check`. That
constrains how every task is written: a task that is "idempotent in
practice" but reports `changed` on every run would make the drift report
cry wolf permanently, and a drift report nobody trusts is worse than no
drift report.

## Task files

| File | Contents |
|---|---|
| `users.yml` | Automation account, authorised keys (`exclusive: true`), scoped sudo, locked root |
| `ssh.yml` | Hardening drop-in, banner, and verification against `sshd -T` |
| `firewall.yml` | ufw default-deny with SSH scoped to `security.management_cidrs` |
| `time.yml` | chrony (timesyncd stopped), timezone, sync verification |
| `audit.yml` | auditd rules for identity, sudoers, sshd and privilege escalation |
| `cis-demo.yml` | CIS-**inspired** demonstration controls — see below |
| `reboot.yml` | Reboot only when `/var/run/reboot-required` exists, never in check mode |
| `validate.yml` | Read-only assertions plus `forge-health` |

## Ordering that matters

- **Firewall.** The SSH allow rule is created *before* the default-deny
  policy. The other order locks Ansible out of the host mid-play.
- **Handlers are flushed early** in `ssh.yml` and `time.yml` so the
  verification that follows tests the new configuration, not the old.
- **`validate: sshd -t -f %s` / `visudo -cf %s`.** A rejected sshd
  config or a malformed sudoers file on a headless VM reachable only
  over SSH is unrecoverable without console access.

## The CIS-inspired controls are not a CIS benchmark

`cis-demo.yml` applies a handful of settings informed by the CIS Ubuntu
Linux Benchmark. It is **not** a benchmark run and must not be reported
as CIS conformance: a real assessment covers several hundred controls,
requires evidence collection, and has scored/not-scored distinctions
this role does not model. The role says so in its own run output. See
`docs/LIMITATIONS.md`.

Disable with `baseline.ubuntu.cis_demo_controls: false`.

Two deliberate omissions, both because the cure is worse than the
disease on a PoC target:

- `-e 2` (immutable audit rules) — would force a reboot for every drift
  reconciliation.
- `Unattended-Upgrade::Automatic-Reboot` — a target that reboots itself
  mid-demonstration is worse than one a few days behind.

## Sudo policy

`NOPASSWD:ALL` for the automation account, because Ansible authenticates
with a key and has no password to offer. That is honest: a configuration
management account is a privileged account. The production
recommendation — a command allowlist per role — is a change to
`users.yml` and a matching narrowing of what the baseline does.

## `forge-health`

Installed at `/usr/local/bin/forge-health`. One command that answers "is
this host in the state FORGE-AI intended?", in text or `--json`. Used by
`validate.yml`, by `scripts/smoke-test.sh`, and available to an operator
or a monitoring system.

## Tags

`linux`, `bootstrap`, `security`, `validation`, `drift`
