# `pxe/` — the boot chain, documented

This directory documents and stores the **static** parts of the network
boot path. It is not where the running configuration comes from.

> **Source of truth:** `ansible/templates/` renders every configuration
> file that actually gets deployed, because they all depend on values
> from `config/poc.yml` — addresses, MAC addresses, ports, host names.
> A static copy of a dnsmasq config in a repository is a copy that
> drifts. What lives here is the material that is genuinely static, plus
> the explanation of how the pieces fit.

## The boot chain, end to end

```text
  VM powers on
      │
      │  DHCP DISCOVER, with DHCP option 93 (client architecture)
      ▼
  dnsmasq  ── bound only to virbr-forge ─────────────────────────────┐
      │                                                              │
      │  arch 0  → undionly.kpxe   (legacy BIOS, TFTP)               │
      │  arch 7  → ipxe.efi        (UEFI x86-64, TFTP)               │
      │  arch 16 → ipxe.efi        (UEFI HTTP Boot, option 60)       │
      │                                                              │
      │  ── every one of those rules carries tag:!ipxe ──────────────┘
      ▼
  iPXE starts, asks DHCP again, and identifies itself
      │  (DHCP option 175, and user-class "iPXE")
      ▼
  dnsmasq  → http://192.168.250.1:8080/boot/boot.ipxe
      │      never a binary, because of tag:!ipxe → no chainload loop
      ▼
  boot.ipxe  → chains /state/${mac:hexhyp}.ipxe
      ▼
  state service decides, per MAC, per boot:
      │
      ├─ new | installing   → the installer, and attempts += 1
      │                        ↳ at the limit: park as failed, boot local
      ├─ installed | ready  → sanboot the local disk
      └─ unknown MAC        → the interactive menu
      │
      ├──────────────► Ubuntu:  kernel + initrd + ds=nocloud;s=…/
      └──────────────► Windows: wimboot → WinPE → setup.exe /unattend
```

## Sub-directories

| Directory | What is here |
|---|---|
| `dnsmasq/` | How the DHCP options work, and why the loop guard is in the config rather than in a script |
| `ipxe/` | The iPXE build options, `checksums.sha256`, and how to build from source |
| `nginx/` | Why HTTP carries everything except the first-stage binary |
| `ubuntu/` | The Ubuntu network boot path, and why there is no netboot image |
| `windows/` | The wimboot chain and the file set it needs |

Each has a `README.md`. None contains a binary: `.gitignore` excludes
`*.kpxe`, `*.efi`, `*.wim`, `wimboot` and every ISO, and
`.github/workflows/security.yml` fails the build if one is committed
anyway.

## Where the running files end up

At deployment time, on the KVM host:

```text
/srv/forge-ai/
├── tftp/                     served by dnsmasq (stage 1 only)
│   ├── undionly.kpxe
│   ├── ipxe.efi
│   └── checksums.sha256
├── http/                     served by the bootsrv container on :8080
│   ├── boot/
│   │   ├── boot.ipxe                    entry point
│   │   ├── menu.ipxe                    fallback
│   │   └── host-<mac>-install.ipxe      one per host
│   ├── ipxe/                 the same binaries, for UEFI HTTP Boot
│   ├── wimboot/wimboot
│   ├── iso/                  the Ubuntu ISO, fetched by casper
│   ├── ubuntu/
│   │   ├── casper/{vmlinuz,initrd}
│   │   └── <hostname>/{user-data,meta-data,vendor-data}
│   └── windows/
│       ├── media/            extracted Windows ISO (also exported over SMB)
│       ├── virtio/           extracted VirtIO drivers (also over SMB)
│       ├── boot-forge.wim    WinPE with the VirtIO drivers injected
│       └── <hostname>/{bootmgr.exe,BCD,boot.sdi,boot.wim,startnet.cmd,Autounattend.xml}
└── state/
    ├── registry.json         MAC → host, written by the ipxe_menu role
    └── <mac>.json            lifecycle state and attempt counter
```

## Inspecting a live boot

```bash
# DHCP conversation, including which architecture the client claimed
sudo tcpdump -i virbr-forge -n 'udp port 67 or udp port 68'

# every artefact the client fetched, in order
sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log

# what dnsmasq decided to offer
sudo journalctl -u forge-dnsmasq -f

# what the state service will hand this MAC next
curl -s http://192.168.250.1:8080/state/52-54-00-25-00-21.ipxe
curl -s http://192.168.250.1:8080/api/state | jq
```

`docs/TROUBLESHOOTING.md` maps each symptom to the layer that produced
it.
