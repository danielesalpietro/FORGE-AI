# `windows_media`

Validates and unpacks the **operator-supplied** Windows Server media.

> No Microsoft binary — ISO, `boot.wim`, `install.wim`, ADK component or
> product key — is stored in this repository. See `docs/LIMITATIONS.md`
> and `THIRD_PARTY_NOTICES.md`.

## The edition check is the point of this role

"Index 1 is the edition I want" is wrong on almost every Windows Server
ISO. Index 1 is normally **Standard Core** — no desktop, no GUI tools —
and the mistake only becomes visible after a 20-minute installation.

`tasks/inspect-wim.yml` reads the image metadata with `wimlib-imagex`
(the `wimtools` package, no Windows machine required), prints every
edition with its index, resolves what `config/poc.yml` selected, and
**fails with the available list** if the selection is not there.

```bash
make windows-images        # the same listing, without a deployment
```

`config/poc.yml` selects by `image_name` in preference to `image_index`;
names are case-sensitive in practice and differ between ISOs.

## Checksums

The ISO's SHA-256 is always computed and recorded in the deployment
report. If `media.windows.iso_sha256` is pinned it is enforced; if not,
the role prints the observed digest with the exact YAML to paste in.
Same policy for the VirtIO ISO — those drivers run in kernel mode on the
target, so a substituted ISO matters.

## VirtIO driver paths

`media.windows.virtio.driver_paths` names per-OS sub-directories
(`viostor/2k25/amd64`) that **change between virtio-win releases**. The
role stats every configured path and fails with the correction command
rather than letting Setup discover it:

- missing `viostor` → Setup reports "We couldn't find any drives"
- missing `NetKVM` → the installed host has no network, so the
  specialize callbacks and Ansible never reach it

## Required vs optional

| Playbook | `windows_media_required` | Behaviour with no ISO |
|---|---|---|
| `site.yml` | `false` | Windows path ends cleanly; Ubuntu deploys |
| `provision-windows.yml` | `true` | Hard failure with the acquisition procedure |

## Outputs

`forge_windows_media` — ISO path, SHA-256, resolved edition and index,
the extracted image locations and the SMB share URL.

## Tags

`media`, `windows`, `validation`
