# `pxe/windows/`

The Windows Server network installation path.

> **No Microsoft binary is stored in this repository.** No ISO, no
> `boot.wim`, no `install.wim`, no ADK component, no product key. The
> operator supplies the media. See `docs/WINDOWS-PROVISIONING.md` for
> how to obtain Windows Server Evaluation media legally, and
> `docs/LIMITATIONS.md` for what that means in practice.

## The chain

```text
iPXE
 └─ wimboot                          the iPXE project's WIM loader
     ├─ bootmgr.exe                  from the operator's ISO
     ├─ BCD                          from the operator's ISO
     ├─ boot.sdi                     from the operator's ISO
     ├─ boot.wim                     WinPE, with VirtIO drivers injected
     ├─ startnet.cmd          ──┐    per host
     └─ Autounattend.xml      ──┤    per host
                                │
        wimboot injects these into \Windows\System32 of the booted image
                                │
     WinPE starts ──────────────┘
      1. drvload   the VirtIO drivers  (storage first)
      2. wpeinit   bring up networking
      3. net use   mount \\192.168.250.1\winmedia
      4. diskpart  clean and convert the disk to GPT
      5. curl      report state=installing
      6. setup.exe /unattend:X:\Windows\System32\Autounattend.xml
                                │
     Windows Setup ─────────────┘
      windowsPE    → partition, select the edition, load drivers
      specialize   → computer name, stage SetupComplete.cmd, report installed
      oobeSystem   → suppress OOBE, set the administrator password
                                │
     SetupComplete.cmd ─────────┘   runs as SYSTEM at the end of Setup
      → Configure-WinRM.ps1         HTTPS listener, scoped firewall
      → qemu-guest-agent
      → report state=configuring
                                │
     Ansible over WinRM/HTTPS ──┘
```

## Why the answer file travels through wimboot

`wimboot` injects any file beyond `bootmgr`/`BCD`/`boot.sdi`/`*.wim`
into `\Windows\System32` of the booted image. That is how each host gets
its own `startnet.cmd` and its own `Autounattend.xml` **without either
ever being written to the shared SMB export** — and the answer file
carries the administrator password, so that matters.

## Why SMB, not HTTP, for `install.wim`

WinPE taken from a Windows installation ISO provides `cmd.exe`,
`diskpart`, `dism`, `drvload`, `wpeinit`, `net.exe` and `setup.exe`. It
does **not** provide PowerShell, and `curl.exe` is not reliably present
across builds. It cannot mount HTTP.

`net.exe` is guaranteed. So the multi-gigabyte `install.wim` comes over
a read-only, anonymous SMB export (`compose/samba/`), and `startnet.cmd`
falls back to `curl.exe` for the small state callback only if it happens
to exist.

The export is SMB2+ only, read-only, and carries no credential.

## VirtIO drivers, injected on Linux

Windows has no in-box VirtIO driver:

- no `viostor` → `diskpart` reports "There are no fixed disks to show",
  and Setup reports "We couldn't find any drives"
- no `NetKVM` → `wpeinit` finds no NIC, the SMB mount times out, and the
  specialize-phase callbacks never reach the boot server

Injecting drivers into a WIM is normally a DISM operation on a Windows
machine. `wimlib-imagex update` does it on Linux, which is what keeps
this fully automated on the Ubuntu control host:

```bash
./scripts/build-winpe.sh              # or: make prepare-windows-media
./scripts/build-winpe.sh --verify-only
```

**Index selection matters.** A Windows installation `boot.wim` holds two
images: index 1 is bare "Microsoft Windows PE", index 2 is "Microsoft
Windows Setup". Only the Setup image boots into the installer, so the
role finds it **by name** rather than assuming an index.

## When you actually need the Windows ADK

`build-winpe.sh` cannot add WinPE *optional components* — PowerShell,
WMI, .NET. Those need the ADK on a Windows workstation.

Nothing in this PoC needs them: `startnet.cmd` is plain batch precisely
so that it does not. If you customise the WinPE stage and find you do,
`docs/WINDOWS-PROVISIONING.md` has the ADK procedure and
`media.windows.winpe_source: prebuilt` consumes the result.

## Never assume index 1

Index 1 on a Windows Server ISO is normally **Standard Core** — no
desktop, no GUI management tools. The mistake only becomes visible after
a 20-minute installation.

```bash
make windows-images        # lists every edition with its index and size
```

`config/poc.yml` selects by `image_name` in preference to `image_index`,
and `windows_media` **fails with the available list** if the configured
edition is not in the image.

## Watching an installation

```bash
virt-viewer --connect qemu:///system poc-windows-01
curl -s http://192.168.250.1:8080/api/state/52-54-00-25-00-22 | jq
ls /srv/forge-ai/logs/guests/poc-windows-01/
```

On the target: `X:\forge-ai.log` during WinPE,
`C:\Windows\Panther\setupact.log` for unattend processing, and
`C:\ProgramData\forge-ai\setupcomplete.log` for the WinRM bootstrap.

`docs/TROUBLESHOOTING.md` maps each Windows symptom to its stage.
