# `pxe/nginx/`

The boot artefact server. Rendered from
`ansible/templates/nginx/boot-server.conf.j2` and mounted read-only into
the `bootsrv` container, which binds **only** to the libvirt bridge
address.

## The transport split

| Transport | Carries | Why |
|---|---|---|
| TFTP (udp/69) | `undionly.kpxe`, `ipxe.efi` — tens of KB | The only thing a firmware PXE ROM can speak |
| HTTP (tcp/8080) | Everything else | TFTP's lock-step acknowledgement makes multi-megabyte transfers slow and fragile across a bridge |

"Everything else" is substantial: a 3 GB Ubuntu ISO fetched by casper, a
~700 MB WinPE image, a 5 GB `install.wim`. Over TFTP those would take
hours and fail often.

## What it serves

| Path | Contents |
|---|---|
| `/boot/` | iPXE scripts. `Cache-Control: no-store`. |
| `/ipxe/` | The iPXE binaries, for UEFI HTTP Boot (arch 16). |
| `/wimboot/` | The wimboot loader. |
| `/iso/` | The Ubuntu ISO. `Accept-Ranges: bytes` — casper uses range requests. |
| `/ubuntu/` | Kernel, initrd, and the per-host NoCloud seed. |
| `/windows/` | Per-host WinPE file set and answer files. `autoindex off`. |
| `/state/`, `/api/` | Proxied to the state service. |
| `/healthz` | Liveness. |

Anything not listed returns **404**. Without that final `location /
{ return 404; }`, a path that fell through would be served from
`/srv/http` — and an autoindex there would expose every rendered answer
file at once.

## Details that matter

**`default_type application/octet-stream`.** Firmware HTTP stacks are
unforgiving about content types. Serving an unknown extension as
octet-stream is what keeps wimboot working.

**`Cache-Control: no-store` on `/state/` and `/boot/`.** The whole point
of the dispatch endpoint is that its answer changes as a host moves
through its lifecycle. A cached response would keep handing out the
installer to a machine that had already installed.

**`gzip off`.** Compressing a WIM or an ISO wastes CPU and confuses
clients that ask for a byte range.

**`send_timeout 600s`.** A 5 GB read over a bridge from a slow client
takes a while.

## Why the answer files are still `0644`

`Autounattend.xml` and the autoinstall seed are world-readable on disk,
because nginx reads them as an unprivileged user inside the container.
The file mode is not the control — they are served over HTTP anyway. The
actual controls are:

1. the provisioning network is isolated;
2. the Windows answer file never reaches the SMB share — `wimboot`
   injects it straight into WinPE's `\Windows\System32`;
3. both are **purged** once the host reports `installed`, and a
   `PURGED.txt` records the exposure window.

`docs/SECURITY.md`, "answer-file credential exposure", states the
residual risk plainly.

## Checking it

```bash
curl -s http://192.168.250.1:8080/healthz | jq
curl -I http://192.168.250.1:8080/boot/boot.ipxe
curl -I http://192.168.250.1:8080/ubuntu/poc-ubuntu-01/user-data
sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log
docker compose --env-file compose/.env -f compose/docker-compose.yml logs bootsrv
```
