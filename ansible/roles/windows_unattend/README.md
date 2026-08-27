# `windows_unattend`

Renders `Autounattend.xml`, `SetupComplete.cmd` and
`Configure-WinRM.ps1` per host, and validates them before a VM ever
boots.

## Where the password lives, and for how long

`Autounattend.xml` carries the local administrator password as
**Base64(UTF-16LE(password + "AdministratorPassword"))** — the encoding
Windows Setup expects when `PlainText` is `false`. Microsoft calls this
"encrypted"; it is **reversible by anyone holding the file**. This
repository calls it obfuscation and mitigates it three ways:

1. it is never written to the SMB share — `wimboot` injects it directly
   into WinPE's `\Windows\System32` (see `windows_winpe`);
2. it is served only on the isolated provisioning segment;
3. `tasks/purge.yml` deletes it once the host reports `installed`, and
   leaves a `PURGED.txt` recording the exposure window.

`docs/SECURITY.md` states the residual risk plainly rather than
pretending the encoding is a control.

The role also **greps the rendered file for the cleartext password** and
fails if it finds it. A template edit that dropped `PlainText=false`
would otherwise publish the real password over HTTP.

## Password complexity is checked before rendering

Windows Setup silently rejects a non-compliant `AdministratorPassword`
and leaves the account with **no password at all**. The host then
installs perfectly and Ansible cannot authenticate to it — a confusing
failure an hour downstream. The assertion up front costs nothing.

## Validation

| Check | Why |
|---|---|
| `xmllint --noout` at render time | Malformed XML makes Setup ignore the file entirely |
| `windowsPE` pass present | Otherwise Setup asks for the disk layout and edition interactively |
| `specialize` pass present | Otherwise no computer name, and `SetupComplete.cmd` is never staged |
| `oobeSystem` pass present | Otherwise Setup stops at the region screen forever |
| No cleartext password | See above |
| `SetupComplete.cmd` + `Configure-WinRM.ps1` return HTTP 200 | The specialize pass downloads them; without them the host has no WinRM listener |

## Why SetupComplete.cmd survives the purge

It carries no credential, and keeping it available makes the "WinRM
listener unavailable" recovery in `docs/TROUBLESHOOTING.md` a one-liner
rather than a re-render.

## Tags

`windows`, `security`, `validation`
