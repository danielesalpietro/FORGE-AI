# Windows provisioning

From bare disk to a machine Ansible can reach over WinRM — and the media
you have to supply first.

---

## What you must provide

> **No Microsoft binary is in this repository.** No ISO, no `boot.wim`,
> no `install.wim`, no ADK component, no product key. Nothing here
> redistributes Microsoft software, and nothing here will.

You supply a Windows Server ISO. The Ubuntu target deploys perfectly
well without one.

### Obtaining evaluation media legally

1. Go to the **Microsoft Evaluation Center**
   (<https://www.microsoft.com/evalcenter>).
2. Choose **Windows Server 2025** (or 2022 — both work here).
3. Select the **ISO** download and complete the registration form.
4. Download it to the KVM host.

It is a free evaluation, typically 180 days, and **you** accept
Microsoft's licensing terms — this project is not a party to them.
Evaluation media is intended for evaluation; production use needs a
licence.

### Pointing the configuration at it

```yaml
media:
  windows:
    iso_path: /srv/forge-ai/iso/windows-server-2025-eval.iso
    iso_sha256: ""              # pin it after the first run
    image_name: "Windows Server 2025 SERVERSTANDARD"
```

### Choosing the edition — and why this matters

```bash
make windows-images
```

```text
  [1] Windows Server 2025 SERVERSTANDARDCORE       6.2 GB
  [2] Windows Server 2025 SERVERSTANDARD           9.8 GB
  [3] Windows Server 2025 SERVERDATACENTERCORE     6.3 GB
  [4] Windows Server 2025 SERVERDATACENTER         9.9 GB
```

**Index 1 is Server Core.** No desktop, no GUI management tools. It is a
perfectly good target — Ansible over WinRM works fine on it — but if
your demonstration expects to show Server Manager on the console, it
will disappoint. And the mistake only becomes visible after a 20-minute
installation.

This is why `config/poc.yml` selects by **name** in preference to index,
and why `windows_media` **fails with the available list** rather than
installing something you did not ask for.

Names are case-sensitive in practice and differ between ISOs. Copy one
verbatim.

---

## The path

```text
iPXE
 └─ wimboot                                the iPXE project's WIM loader
     ├─ bootmgr.exe, BCD, boot.sdi         from your ISO
     ├─ boot.wim                           WinPE + injected VirtIO drivers
     ├─ startnet.cmd          ─┐  per host, injected by wimboot
     └─ Autounattend.xml      ─┘  into \Windows\System32
         └─ WinPE
             1. drvload    VirtIO drivers, storage first
             2. wpeinit    bring up networking
             3. net use    mount \\192.168.250.1\winmedia
             4. diskpart   clean, convert to GPT
             5. curl       report state=installing
             6. setup.exe /unattend:X:\Windows\System32\Autounattend.xml
                 └─ windowsPE    partition, select edition, load drivers
                 └─ specialize   computer name, stage SetupComplete.cmd,
                                 report state=installed
                 └─ oobeSystem   suppress OOBE, set the password
                     └─ SetupComplete.cmd    runs as SYSTEM
                         └─ Configure-WinRM.ps1
                         └─ qemu-guest-agent
                         └─ report state=configuring
                             └─ Ansible over WinRM/HTTPS
```

---

## Three decisions worth explaining

### 1. The answer file travels through wimboot

`wimboot` injects any file beyond `bootmgr`/`BCD`/`boot.sdi`/`*.wim`
into `\Windows\System32` of the booted WinPE image.

That is how each host receives its own `startnet.cmd` and its own
`Autounattend.xml` **without either ever being written to the shared SMB
export**. The answer file carries the administrator password, so this
matters more than it might appear.

### 2. `install.wim` comes over SMB, not HTTP

WinPE taken from a Windows installation ISO provides `cmd.exe`,
`diskpart`, `dism`, `drvload`, `wpeinit`, `net.exe` and `setup.exe`.

It does **not** provide PowerShell. `curl.exe` is not reliably present
across builds. And it cannot mount HTTP at all.

`net.exe` is guaranteed. So the multi-gigabyte `install.wim` comes over
a read-only, anonymous SMB export (`compose/samba/`, SMB2+ only,
carrying no credential), and `startnet.cmd` uses `curl.exe` only for the
small state callback, and only if it happens to exist.

### 3. VirtIO drivers are injected on Linux

Windows has no in-box VirtIO driver:

| Missing | Symptom |
|---|---|
| `viostor` | `diskpart`: "There are no fixed disks to show". Setup: "We couldn't find any drives." |
| `NetKVM` | `wpeinit` finds no NIC, the SMB mount times out, and the specialize callbacks never reach the boot server |

Injecting drivers into a WIM is normally a DISM operation on a Windows
machine. **`wimlib-imagex update` does it on Linux**, which is what keeps
this fully automated on the Ubuntu control host.

```bash
./scripts/build-winpe.sh
./scripts/build-winpe.sh --verify-only
```

**Index selection matters here too.** A Windows installation `boot.wim`
holds two images: index 1 is bare "Microsoft Windows PE", index 2 is
"Microsoft Windows Setup". Only the Setup image boots into the
installer, so the role finds it **by name**.

The drivers land in `\Windows\System32\drivers\forge\` and are loaded by
`startnet.cmd` with `drvload` — simpler than offline registration,
visible in the WinPE log, and independent of any particular release's
driver-store layout.

---

## `Autounattend.xml`

Four passes. Each one that is missing turns an unattended installation
into an interactive one.

| Pass | Configures | If absent |
|---|---|---|
| `windowsPE` | Disk layout, edition, VirtIO `DriverPaths`, EULA | Setup asks for the disk and edition interactively |
| `offlineServicing` | UAC | — |
| `specialize` | Computer name, timezone, RDP, stages `SetupComplete.cmd` | No computer name, and the WinRM bootstrap never runs |
| `oobeSystem` | OOBE suppression, administrator password | Setup stops at the region screen forever |

### The disk layout

UEFI/GPT, three partitions:

| Order | Type | Size | Result |
|---|---|---|---|
| 1 | EFI | 260 MB | FAT32, labelled `System` |
| 2 | MSR | 16 MB | Microsoft Reserved |
| 3 | Primary | remainder | NTFS, `C:`, labelled `Windows` |

`WillWipeDisk` is `true`, and `startnet.cmd` also cleans the disk before
Setup runs. A leftover ESP from a previous attempt is the single most
common cause of a silent "Windows cannot be installed to this disk".

### The administrator password

```xml
<AdministratorPassword>
  <Value>UABhAHMAcwB3AG8AcgBkAEEAZABtAGkAbgAuLi4=</Value>
  <PlainText>false</PlainText>
</AdministratorPassword>
```

That is **Base64(UTF-16LE(password + "AdministratorPassword"))**, the
encoding Windows expects when `PlainText` is `false`.

Microsoft calls this "encrypted". **It is reversible by anyone holding
the file.** This repository calls it obfuscation, and:

- the file is never written to the SMB share;
- it is served only on the isolated provisioning network;
- it is purged once the host reports `installed`, with a `PURGED.txt`
  recording the exposure window;
- a test asserts the cleartext password never appears in the rendered
  file;
- CI fails if `PlainText=true` ever appears in the template.

`docs/SECURITY.md` states the residual risk rather than pretending the
encoding is a control.

**Complexity is checked before rendering.** Windows Setup silently
rejects a non-compliant password and leaves the Administrator account
with **no password at all** — the host then installs perfectly and
Ansible cannot authenticate to it. `windows_unattend` asserts ≥14
characters with upper, lower and digit, up front.

### No product key

Evaluation media installs unkeyed, so no `<ProductKey>` element is
emitted. Activation is out of scope, and `config/schema/poc.schema.json`
enforces `product_key` as **empty** so one cannot be committed.

---

## `SetupComplete.cmd`

Windows Setup runs it **once, as SYSTEM**, after the last reboot and
before the first logon. It is staged during `specialize`, downloaded
from the boot server.

1. Record the deployment identity into
   `C:\ProgramData\forge-ai\provisioning.json`.
2. Run `Configure-WinRM.ps1`.
3. Install `qemu-guest-agent` from the VirtIO share.
4. Report `configuring` — or `failed` if step 2 failed.
5. Upload its own log to the boot server.

**Failure mode, and it is the common one:** if this never runs, the host
installs correctly but has no WinRM listener. Ansible cannot reach it,
and nothing says why.

Recovery, from the VM console:

```powershell
Get-Content C:\ProgramData\forge-ai\setupcomplete.log
powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Configure-WinRM.ps1
```

`Configure-WinRM.ps1` is deliberately **not** purged, precisely so this
is a one-liner.

---

## `Configure-WinRM.ps1`

What it establishes:

| Setting | Value | Why |
|---|---|---|
| Listener | HTTPS on 5986 | The plaintext listener is **removed** |
| Certificate | Self-signed, SANs for hostname, FQDN and IP | Nothing to trust it with yet |
| `AllowUnencrypted` | `false` | |
| Basic auth | **disabled** | |
| CredSSP | **disabled** | Credential delegation is not needed here |
| Negotiate / Kerberos | enabled | NTLM in a workgroup; Kerberos once domain-joined |
| Firewall | Scoped to `security.management_cidrs` | And the broad built-in WinRM rules are **disabled** — otherwise the scoping achieves nothing |
| RDP | Off unless `windows_rdp_enabled` | |

It then **verifies** the listener answers before reporting success —
`Test-NetConnection` plus a check that an HTTPS listener actually
exists. A script that configures something and does not check is a
script that reports success on a broken host.

---

## The Windows baseline

| Area | What |
|---|---|
| SMB | SMBv1 server and client off, signing required |
| Firewall | All profiles on, inbound block, scoped management rule, logging |
| Defender | **Validated, not configured** — the failure worth catching is Defender being *off* |
| TLS | SChannel baseline, .NET strong crypto |
| Accounts | Guest disabled, local policy, administrator group review, LAPS readiness |
| Updates | Policy-driven: `check_only` by default |
| Event logs | Sized, audit subcategories enabled |
| Guest agent | Second chance over WinRM if the SMB install missed |

### TLS ordering is not accidental

**TLS 1.2 is enabled before SSL 3.0, TLS 1.0 and TLS 1.1 are disabled.**
WinRM rides on SChannel, so disabling a protocol the controller relies
on cuts the connection the play is running over.

### Windows Update defaults to `check_only`

An update run on a fresh Server image routinely takes 30–60 minutes and
reboots two or three times. That is not what anyone wants
mid-demonstration. The report records how many updates are outstanding,
so the patch posture is visible either way.

```yaml
baseline:
  windows:
    windows_update_mode: install    # check_only | download | install | disabled
```

### LAPS is documented, not implemented

The PoC uses one local administrator password from the vault: a shared
static credential. Windows LAPS is the answer, but it needs Entra ID or
Active Directory to store the rotated password, and this host is a
standalone workgroup member.

`accounts.yml` reports readiness — module present, domain joined, can
enable — so the gap is visible rather than glossed over.

---

## When you actually need the Windows ADK

`build-winpe.sh` **cannot** add WinPE optional components: PowerShell,
WMI, .NET. Those require the ADK on a Windows workstation.

Nothing in this PoC needs them — `startnet.cmd` is plain batch precisely
so that it does not. If you customise the WinPE stage and find you do:

**On a Windows workstation:**

1. Install the Windows ADK and the **WinPE add-on**.
2. Open *Deployment and Imaging Tools Environment* as Administrator.

```powershell
copype amd64 C:\WinPE_amd64
Dism /Mount-Image /ImageFile:C:\WinPE_amd64\media\sources\boot.wim /Index:1 /MountDir:C:\WinPE_amd64\mount

$packages = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"$packages\WinPE-WMI.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"$packages\WinPE-NetFX.cab"
Dism /Add-Package /Image:C:\WinPE_amd64\mount /PackagePath:"$packages\WinPE-PowerShell.cab"

Dism /Add-Driver /Image:C:\WinPE_amd64\mount /Driver:D:\viostor\2k25\amd64 /Recurse
Dism /Add-Driver /Image:C:\WinPE_amd64\mount /Driver:D:\NetKVM\2k25\amd64 /Recurse

Dism /Unmount-Image /MountDir:C:\WinPE_amd64\mount /Commit
```

Then copy `C:\WinPE_amd64\media\sources\boot.wim` to the KVM host, and
point the configuration at it:

```yaml
media:
  windows:
    winpe_source: prebuilt
    winpe_prebuilt_path: /srv/forge-ai/iso/boot-custom.wim
```

The order matters: **packages before drivers**, and `/Commit` on
unmount or the changes are discarded.

---

## Watching and debugging

```bash
virt-viewer --connect qemu:///system poc-windows-01
make state
./scripts/wait-for-winrm.sh poc-windows-01 --timeout 1800
ls -la /srv/forge-ai/logs/guests/poc-windows-01/
```

`wait-for-winrm.sh` probes **TCP, then TLS, then WS-Man** separately,
because "WinRM is not working" has three very different causes and a
timeout that does not say which is nearly useless.

On the target:

| Path | Stage |
|---|---|
| `X:\forge-ai.log` | WinPE — logs each of the six steps |
| `C:\Windows\Panther\setupact.log` | Unattend processing |
| `C:\Windows\Panther\setuperr.log` | Setup errors |
| `C:\ProgramData\forge-ai\setupcomplete.log` | The WinRM bootstrap |
| `C:\ProgramData\forge-ai\winrm.json` | Certificate thumbprint, port, scopes |

Test WinRM by hand:

```bash
openssl s_client -connect 192.168.250.22:5986 </dev/null 2>/dev/null | openssl x509 -noout -subject -dates

cd ansible && ansible poc-windows-01 -m ansible.windows.win_ping \
  --vault-password-file ../.vault-password
```

---

## Rebuilding

```bash
./scripts/set-boot-state.sh poc-windows-01 new    # asks first: this wipes the disk
make provision-windows
```

Setting an installed host back to `new` queues a **reinstall**. The
script confirms before doing it, which is why it asks rather than just
obeying.
