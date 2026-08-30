# `windows_winpe`

Builds the network-bootable WinPE image and stages a per-host boot set.

## The chain

```text
iPXE  ->  wimboot  ->  bootmgr.exe + BCD + boot.sdi + boot.wim
      ->  startnet.cmd  ->  setup.exe /unattend:Autounattend.xml
```

`wimboot` (from the iPXE project — see `THIRD_PARTY_NOTICES.md`) also
**injects any additional file it is handed into `\Windows\System32`** of
the booted image. That is how each host receives its own
`startnet.cmd` and its own `Autounattend.xml` without either ever being
written to a shared directory on the KVM host — the answer file carries
the administrator password, so this matters.

## Driver injection without Windows

WinPE has no in-box VirtIO driver:

- no `viostor` → `diskpart` reports "There are no fixed disks to show"
- no `NetKVM` → `wpeinit` finds no NIC and the SMB mount times out

Injecting files into a WIM is normally a DISM operation on a Windows
machine. `wimlib-imagex update` does it on Linux, which is what keeps
this role fully automated on the Ubuntu control host. Operators who need
a customised WinPE (extra optional components, PowerShell) can build one
with the Windows ADK; `docs/WINDOWS-PROVISIONING.md` covers that path
and `media.windows.winpe_source: prebuilt` consumes the result.

**Index selection matters.** A Windows installation `boot.wim` holds two
images: index 1 is bare "Microsoft Windows PE", index 2 is "Microsoft
Windows Setup". Only the Setup image boots into the installer, so the
role finds it by name rather than assuming an index.

The drivers land in `\Windows\System32\drivers\forge\` and are loaded by
`startnet.cmd` with `drvload` — simpler than offline registration,
visible in the WinPE log, and independent of the driver-store layout of
any particular Windows release.

The role then re-reads the image and **asserts** that `.inf` files are
actually there.

## Case-insensitive media layout

`7z` preserves the ISO's own casing, which varies between Windows
releases (`boot/BCD`, `Boot/bcd`, `BOOT/BCD`). The role locates
`bootmgr.efi`, `BCD` and `boot.sdi` with `find -iname` rather than
guessing.

## CRLF

`startnet.cmd` is rendered with `newline_sequence: "\r\n"`. A LF-only
batch file fails inside WinPE in ways that look like a corrupted image.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `winpe_force_rebuild` | `false` | Rebuild `boot-forge.wim` from pristine media |
| `winpe_driver_inf_names` | viostor, vioscsi, netkvm, balloon, vioser | `drvload` order — storage first |
| `winpe_network_retries` | `30` | Gateway ping attempts in `startnet.cmd` |
| `wimboot_version` / `wimboot_sha256` | `v2.8.0` / unpinned | Pin the digest after the first run |

## Tags

`windows`, `media`, `validation`
