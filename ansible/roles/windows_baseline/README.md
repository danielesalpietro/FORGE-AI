# `windows_baseline`

Desired state for the Windows Server target.

## Check mode is not enough here, and the role says so

Several `ansible.windows` and `community.windows` modules support check
mode only partially; `win_shell` and `win_command` support it not at
all and are skipped entirely. A drift run relying on check mode alone
would therefore be **blind to everything those tasks manage** — SMBv1,
firewall defaults, the execution policy, the event log sizing.

So every control here has a matching **read-only probe** in
`ansible/inventories/poc/group_vars/windows/main.yml`
(`forge_windows_probes`). `tasks/validate.yml` runs them, compares
observed against expected, and fails with the specific mismatches. The
drift report combines both sources and labels which came from where.

This is the honest position: `docs/OPERATIONS.md` documents the
check-mode limitations rather than claiming coverage the modules do not
provide.

## Task files

| File | Contents |
|---|---|
| `smb.yml` | SMBv1 server + client off, SMB signing required |
| `firewall.yml` | All profiles on, inbound block, WinRM scoped to `management_cidrs`, built-in broad rules disabled, RDP controlled |
| `defender.yml` | Validated, not configured — the failure worth catching is Defender being *off* |
| `tls.yml` | SChannel baseline, .NET strong crypto |
| `accounts.yml` | Guest disabled, local policy, administrator group review, LAPS readiness |
| `updates.yml` | Policy-driven: `check_only` / `download` / `install` / `disabled` |
| `eventlog.yml` | Log sizing and audit subcategories |
| `guest-agent.yml` | Second chance at qemu-guest-agent over WinRM |
| `validate.yml` | `win_ping` plus the read-only probes |

## Ordering that matters

**TLS 1.2 is enabled before the older protocols are disabled.** WinRM
rides on SChannel, so disabling a protocol the controller relies on cuts
the connection the play is running over. The order is not accidental.

**The broad built-in WinRM firewall rules are disabled** after the
scoped rule exists. Leaving them enabled means the scope achieves
nothing — Windows ships them scoped to `Any`.

## Windows Update defaults to `check_only`

An update run on a fresh Server image routinely takes 30–60 minutes and
reboots two or three times. That is not what anyone wants mid-demo. The
report records how many updates are outstanding, so the patch posture is
visible either way. Change with
`baseline.windows.windows_update_mode: install`.

## LAPS is documented, not implemented

The PoC uses a single local administrator password held in Ansible
Vault: a **shared static credential**. Windows LAPS is the answer, but
it needs Entra ID or Active Directory to store the rotated password and
this host is a standalone workgroup member. `accounts.yml` reports
readiness — module present, domain joined, can enable — so the gap is
visible rather than glossed over. See `docs/SECURITY.md`, "WinRM
credential theft".

## Tags

`windows`, `bootstrap`, `security`, `validation`, `drift`
