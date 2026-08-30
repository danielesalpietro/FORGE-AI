# `ubuntu_media`

Downloads, verifies and unpacks the Ubuntu Server ISO.

## Why only two files are extracted

Ubuntu 24.04 ships **no `netboot.tar.gz` for Server**. The supported
network installation path is:

1. boot `casper/vmlinuz` + `casper/initrd`, extracted from the ISO;
2. pass `url=<http url to the ISO>` on the kernel command line so casper
   fetches the ISO itself and finds the squashfs inside it.

So the role extracts the kernel and initrd, and publishes the whole ISO
over HTTP for step 2. `7z` is used rather than a loop mount: it works
without root inside a container and leaves nothing behind if a play is
interrupted.

## Checksum policy

| `media.ubuntu.iso_sha256` | Behaviour |
|---|---|
| pinned (64 hex chars) | Authoritative. Works air-gapped. The remote `SHA256SUMS` is not fetched. |
| empty (default) | The official `https://releases.ubuntu.com/24.04/SHA256SUMS` is fetched and the digest for this filename is used. |

If neither yields a checksum the role **fails** rather than installing
from unverified media — that is the "tampered ISO" threat in
`docs/SECURITY.md`. Accept it deliberately with
`-e ubuntu_media_verify_checksum=false`.

The role re-stats the file afterwards and asserts the digest, so a
partial download cannot slip through.

## Publishing the ISO

A hard link into `http/iso/` is attempted first to avoid a second
multi-gigabyte copy. If `iso_dir` and `http_root` are on different
filesystems the link fails and the role copies instead — a symlink would
not resolve out of the `bootsrv` container's bind mount.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `ubuntu_media_verify_checksum` | `true` | Turn off only deliberately |
| `ubuntu_media_force_download` | `false` | Re-download a matching ISO |
| `ubuntu_media_download_timeout` | `3600` | Seconds |

## Outputs

`forge_ubuntu_media` — path, SHA-256, size and the extracted boot file
locations. Quoted in the deployment report's "Source media" table.

## Tags

`media`, `linux`, `validation`
