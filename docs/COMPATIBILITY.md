# Compatibility

Exactly what was tested, and what is expected to work but has not been.

> The distinction matters. "Should work" and "was run" are different
> claims, and this page keeps them apart.

---

## Control host

| Component | Version | Status |
|---|---|---|
| Ubuntu Server | **24.04.1 LTS (noble)** | Validated |
| Kernel | 6.8.0-51-generic | Validated |
| Architecture | x86_64 | Validated |
| Ubuntu Server | 22.04 LTS | Untested — package names and OVMF paths differ |
| Debian 12 | — | Untested |
| RHEL / Rocky 9 | — | Untested; the auditd restart path differs (see `ubuntu_baseline/handlers`) |

`check-prerequisites.sh` warns on anything other than 24.04 rather than
refusing, so an experiment is possible — but nothing below has been
verified there.

---

## Virtualisation

| Component | Version | Status |
|---|---|---|
| libvirt | 10.0.0 | Validated |
| QEMU | 8.2.2 | Validated |
| OVMF (`ovmf` package) | 2024.02-2 | Validated |
| `virt-install` | 4.1.0 | Validated |
| Nested virtualisation | — | Works; installations are noticeably slower |

The OVMF path differs between distributions. The prerequisite check
looks for `/usr/share/OVMF/OVMF_CODE_4M.fd`,
`/usr/share/OVMF/OVMF_CODE.fd` and `/usr/share/ovmf/OVMF.fd` in that
order.

---

## Control plane

| Component | Pinned version | Status |
|---|---|---|
| Docker Engine | 27.3.1 | Validated |
| Docker Compose | v2.29.7 | Validated — **v1 is not supported** |
| PostgreSQL | `16.4-alpine3.20` | Validated |
| Gitea | `1.22.6-rootless` | Validated |
| Semaphore | `v2.10.34` | Validated |
| nginx | `1.27.2-alpine3.20` | Validated |
| Python (containers) | `3.12.7-alpine3.20` | Validated |
| Alpine (samba) | `3.20.3` | Validated |

Every tag is pinned and CI **fails** on `:latest`. Digest pinning is the
production recommendation; the PoC pins tags so `make bootstrap` works
on a fresh host without a registry lookup.

### Compose v2 only

`docker compose` (the plugin), not `docker-compose` (the standalone v1).
The stack uses `depends_on.condition: service_healthy`, `profiles`,
`--wait` and `deploy.resources.limits`, none of which v1 honours.

---

## Ansible

| Component | Version | Status |
|---|---|---|
| ansible-core | **2.17.5** | Validated |
| ansible-core | 2.18, 2.19 | Works; 2.19 deprecates `DEFAULT_UNDEFINED_VAR_BEHAVIOR`, which is why `ansible.cfg` does not set it |
| ansible-core | < 2.17 | Unsupported |
| Python (control node) | 3.12.3 | Validated |
| Python | 3.11 | Works |
| Python | 3.13 | Untested — note `crypt` was removed, so `create-secrets.sh` uses `openssl passwd -6` as its fallback |

### Collections

| Collection | Constraint | Tested |
|---|---|---|
| `ansible.posix` | `>=1.5.4,<3.0.0` | 1.6.2 |
| `ansible.windows` | `>=2.5.0,<4.0.0` | 2.5.0 |
| `community.windows` | `>=2.2.0,<4.0.0` | 2.3.0 |
| `community.general` | `>=9.0.0,<12.0.0` | 9.5.1 |
| `community.libvirt` | `>=1.3.0,<2.0.0` | 1.3.0 |
| `community.docker` | `>=3.10.0,<5.0.0` | 3.13.0 |
| `community.crypto` | `>=2.20.0,<4.0.0` | 2.22.3 |

Installing the `ansible` distribution from PyPI (10.x–12.x) provides all
of them, which is what CI and the devcontainer do — it removes a
dependency on Galaxy being reachable.

### Python libraries

| Library | Constraint | Tested |
|---|---|---|
| `pywinrm` | `>=0.4.3,<0.6` | 0.5.0 |
| `pypsrp` | `>=0.8.1,<1.1` | 0.8.1 |
| `libvirt-python` | `>=10.0.0` | 10.0.0 |
| `jsonschema` | `>=4.21,<5` | 4.23.0 |
| `PyYAML` | `>=6.0,<7` | 6.0.2 |
| `Jinja2` | `>=3.1.4,<4` | 3.1.4 |

`pywinrm[credssp]` is deliberately **not** installed: CredSSP is
disabled on the targets.

---

## Target operating systems

### Ubuntu

| Version | Status |
|---|---|
| **24.04.3 LTS live-server amd64** | Validated |
| 24.04.x (other point releases) | Expected to work — update `iso_url` and `iso_path` together |
| 22.04 LTS | Expected to work, with one change: cloud-init predates the `nocloud` rename, so the iPXE template needs `ds=nocloud-net;s=` |
| 20.04 LTS | Untested; the autoinstall schema differs |
| Desktop ISO | **Not supported** — different layout, no Subiquity autoinstall |

### Windows

| Version | Status |
|---|---|
| **Windows Server 2025 Evaluation** | Primary target |
| Windows Server 2022 Evaluation | Expected to work — set `virtio.driver_paths` to the `2k22` sub-directories |
| Windows Server 2019 | Expected to work; WinPE is older, so verify `curl.exe` is present for the state callback |
| Windows 10 / 11 | Not a target — the answer file assumes a Server edition |

**Operator-supplied.** No Microsoft media is redistributed here.

---

## VirtIO drivers

| Component | Tested |
|---|---|
| `virtio-win` | 0.1.266 |

The per-OS sub-directory names **change between releases**:

| virtio-win | Server 2025 | Server 2022 |
|---|---|---|
| 0.1.266 | `viostor/2k25/amd64` | `viostor/2k22/amd64` |
| 0.1.240 | `viostor/2k22/amd64` | `viostor/2k22/amd64` |

`windows_media` stats every configured path and **fails with the
correction command** rather than letting Setup discover it.

---

## Boot chain

| Component | Version | Source |
|---|---|---|
| iPXE (`ipxe`, `ipxe-qemu`) | 1.21.1+git-20240329 | Ubuntu 24.04 packages |
| iPXE (built) | `v1.21.1` | Pinned git tag |
| wimboot | `v2.8.0` | iPXE project releases |
| dnsmasq | 2.90 | Ubuntu 24.04 |
| wimlib (`wimtools`) | 1.14.4 | Ubuntu 24.04 |
| p7zip | 16.02 | Ubuntu 24.04 |
| Samba | 4.19 | Alpine 3.20 |

---

## Development tooling

| Tool | Version | Used by |
|---|---|---|
| `ansible-lint` | 24.7+ | `make lint-ansible`, CI — **production profile** |
| `yamllint` | 1.35+ | `make lint-yaml`, CI |
| ShellCheck | 0.9.0 | `make lint-shell`, CI |
| `markdownlint-cli` | 0.42.0 | CI |
| `pytest` | 8.2+ | 204 unit tests |
| `bats` | 1.10+ | 29 shell tests |
| Molecule | 24.2+ | `make test-molecule` |
| Trivy | via `trivy-action@0.28.0` | CI |
| Gitleaks | via `gitleaks-action@v2` | CI |

---

## Reference deployment

What the numbers below were measured on:

| | |
|---|---|
| CPU | AMD Ryzen 9 5950X, 16 cores |
| RAM | 64 GB |
| Storage | NVMe SSD |
| OS | Ubuntu Server 24.04.1 LTS |

| Stage | Duration |
|---|---|
| `make bootstrap` | ~5 min |
| `make prepare-media` (Ubuntu) | ~6 min, mostly download |
| `make prepare-media` (Windows) | ~8 min, mostly extraction |
| Ubuntu installation | ~11 min |
| Windows installation | ~22 min |
| `make configure` | ~4 min |
| `make validate-deployment` | ~3 min |
| **Total, from nothing** | **~55 min** |

On the 16 GB minimum with spinning disk, expect roughly double.

---

## Updating this page

When you test a version this page does not list, add it with its status.
The pull request template has a checkbox for exactly this, because a
compatibility page that is not maintained is worse than none — it makes
a claim nobody has checked.
