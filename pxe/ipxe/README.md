# `pxe/ipxe/`

iPXE is the first code a target machine executes over the network. That
is worth taking seriously.

## Where the binaries come from

Two sources, selected by `pxe.ipxe.source` in `config/poc.yml`:

### `distro` (default)

Copied from the Ubuntu `ipxe` and `ipxe-qemu` packages by
`scripts/download-ipxe-assets.sh`. **apt has already verified the
distribution's signature**, so nothing unsigned enters the boot chain
and there is no separate checksum to manage.

```text
/usr/lib/ipxe/undionly.kpxe   → legacy BIOS
/usr/lib/ipxe/ipxe.efi        → UEFI x86-64
/usr/lib/ipxe/ipxe32.efi      → UEFI IA32
```

### `build`

Compiled from a pinned iPXE git tag:

```bash
./scripts/download-ipxe-assets.sh --build --ref v1.21.1
```

Slower, needs a toolchain, and produces a binary built from source the
operator can read. The build enables the commands the boot scripts and
the rescue menu use — `ping`, `nslookup`, `console`, `reboot`, `params`,
`sha256sum` — via a `config/local/general.h` override the script writes.

## `checksums.sha256`

Written by `download-ipxe-assets.sh` into `/srv/forge-ai/tftp/` after
staging, and checked by `./scripts/verify-checksums.sh`. It records what
is actually being served, so a later change is visible even when the
source was a signed package.

## wimboot

`wimboot` is the iPXE project's Windows Imaging loader, downloaded from
the project's GitHub releases. Its licence and the attribution it
requires are in `THIRD_PARTY_NOTICES.md`.

It is unpinned on a first run, and the script **says so loudly** rather
than implying it verified something it did not:

```bash
export FORGE_WIMBOOT_SHA256=<the digest it printed>
```

or set `wimboot_sha256` in
`ansible/roles/windows_winpe/defaults/main.yml`.

## Secure Boot

The PoC runs with Secure Boot **off** (`<feature enabled="no"
name="secure-boot"/>` in the domain XML). The distribution's `ipxe.efi`
is not signed by a key in the default OVMF `db`, and neither is the
Ubuntu kernel as chained by iPXE.

This is a real limitation, not an oversight —
`docs/SECURITY.md`, "unsigned boot components", records what it means
and what a production deployment would do instead (a shim signed by the
Microsoft UEFI CA, or enrolling a local key in the firmware).

## The scripts

Rendered from `ansible/templates/ipxe/` by the `ipxe_menu` role:

| Script | Purpose |
|---|---|
| `boot.ipxe` | Entry point. Chains `/state/${mac:hexhyp}.ipxe`. |
| `menu.ipxe` | Fallback for an unknown MAC, and the rescue menu. Defaults to **local boot** on timeout. |
| `host-<mac>-install.ipxe` | The installer for one host. |

The state service, not these scripts, decides which one a given boot
receives — see `compose/state-service/app.py`.

## Debugging from the iPXE prompt

Interrupt the boot with `Ctrl+B`:

```text
ifstat                                  # link state and MAC
dhcp                                    # re-run DHCP, see what is offered
route                                   # what it got
chain http://192.168.250.1:8080/boot/menu.ipxe
imgfetch http://192.168.250.1:8080/healthz    # is HTTP reachable at all?
```
