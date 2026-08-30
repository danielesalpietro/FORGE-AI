# `pxe/dnsmasq/`

The rendered configuration is produced by
`ansible/templates/dnsmasq/provisioning.conf.j2` and installed at
`/etc/forge-ai/dnsmasq.conf` by the `pxe_server` role. This page
explains what it does and why.

## A dedicated instance, not a drop-in

FORGE-AI runs its **own** dnsmasq, as a systemd unit
(`forge-dnsmasq.service`), bound to the libvirt bridge and nothing else.

A drop-in under `/etc/dnsmasq.d/` would change the behaviour of whatever
dnsmasq the host already runs — on a desktop, often the one
NetworkManager owns. That is precisely the "PXE DHCP on a production
LAN" accident this project warns about. A dedicated unit also means
teardown can stop DHCP without touching host networking.

The role stops and disables the packaged `dnsmasq` service and **says
so** in the run output. It is never silent.

## libvirt must not also serve DHCP

`ansible/templates/libvirt/network.xml.j2` defines the network with
`<dns enable="no"/>` and **no `<dhcp>` element**. libvirt only spawns its
own dnsmasq when a network needs DHCP or DNS; with neither, it creates
the bridge and the NAT rules and stops.

Two DHCP servers on one bridge is the classic cause of *intermittent*
PXE failure — the kind that gets blamed on everything except DHCP. The
`libvirt_network` role checks for
`/var/lib/libvirt/dnsmasq/<network>.conf` after starting the network and
fails immediately if it exists.

## Architecture detection

RFC 4578 DHCP option 93 tells the server what the client is:

| Value | Client | Tag | Served |
|---|---|---|---|
| 0 | Intel x86 legacy BIOS PXE | `bios` | `undionly.kpxe` over TFTP |
| 6 | EFI IA32 | `efi32` | `ipxe32.efi` over TFTP |
| 7, 9 | EFI x86-64 | `efi64` | `ipxe.efi` over TFTP |
| 16 | EFI x86-64 HTTP Boot (UEFI 2.5+) | `efihttp` | `ipxe.efi` over **HTTP** |

Arch 16 also needs `dhcp-option-force=tag:efihttp,60,HTTPClient`: the
firmware will not accept a URL as a boot filename without the vendor
class being set.

## Why the chainload loop cannot happen

iPXE identifies itself two ways once it is running — DHCP option 175
(its encapsulated options) and the user class `iPXE`. Both set the same
tag:

```text
dhcp-match=set:ipxe,175
dhcp-userclass=set:ipxe,iPXE
```

Every "hand over a binary" rule then carries `tag:!ipxe`:

```text
dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi                    # firmware only
dhcp-boot=tag:ipxe,http://192.168.250.1:8080/boot/boot.ipxe
```

So iPXE can never be told to load iPXE again. Without this, a client
loads iPXE, iPXE asks DHCP, gets told to load iPXE, and loops forever —
`docs/TROUBLESHOOTING.md`, "iPXE chainloading loop".

## Static reservations

One `dhcp-host` line per configured host, with an `infinite` lease:

```text
dhcp-host=52:54:00:25:00:21,192.168.250.21,poc-ubuntu-01,set:52-54-00-25-00-21,infinite
```

The `set:` tag is the MAC in hyphen form — the same string iPXE produces
with `${mac:hexhyp}` and the same one the state service uses to name its
files. `make validate` rejects a reservation that falls inside the
dynamic pool, because that eventually collides.

## Validation before it is applied

The template uses `validate: dnsmasq --test --conf-file=%s`, and the
systemd unit repeats the test in `ExecStartPre`. From a client's point
of view a dnsmasq that refuses to start is indistinguishable from a
network with no DHCP at all, so a bad file must never reach a restart.

## Checking it

```bash
sudo dnsmasq --test --conf-file=/etc/forge-ai/dnsmasq.conf
sudo systemctl status forge-dnsmasq
sudo journalctl -u forge-dnsmasq -f
sudo ss -lnup 'sport = :67'
sudo ss -lnup 'sport = :69'
```
