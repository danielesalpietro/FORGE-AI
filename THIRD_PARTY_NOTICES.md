# Third-party notices

Every component this project bundles, downloads or depends on, with its
licence and the attribution it requires.

> **This repository redistributes no third-party binary.** Everything
> below is either downloaded at deployment time from its upstream, or
> pulled as a container image. The notices are here because
> understanding what runs on your infrastructure — and under what terms
> — is part of running it.

---

## Downloaded at deployment time

### iPXE

- **Project:** <https://ipxe.org>
- **Source:** <https://github.com/ipxe/ipxe>
- **Licence:** GPL-2.0-or-later, with an additional permission (the
  "UBDL" exception) allowing linkage with unmodified binary distribution
  libraries
- **Used for:** Network boot. `undionly.kpxe` for legacy BIOS,
  `ipxe.efi` for UEFI x86-64.
- **Obtained from:** The Ubuntu `ipxe` and `ipxe-qemu` packages by
  default, or built from a pinned git tag with
  `./scripts/download-ipxe-assets.sh --build`.

> **Attribution must be preserved.** iPXE's licence requires that its
> copyright notice and licence text remain intact. This project does not
> modify iPXE binaries, does not rebrand its boot banner, and does not
> strip its identification. When building from source
> (`--build`), only a `config/local/general.h` override is applied to
> enable additional commands; no iPXE source file is modified.
>
> The iPXE boot banner, which identifies the project and its version, is
> left visible on every boot.

### wimboot

- **Project:** <https://ipxe.org/wimboot>
- **Source:** <https://github.com/ipxe/wimboot>
- **Licence:** GPL-2.0-or-later
- **Used for:** Loading WinPE from iPXE. It is what makes network
  installation of Windows possible without a WDS server.
- **Obtained from:** The project's GitHub releases, at deployment time.
- **Version:** `v2.8.0` (see
  `ansible/roles/windows_winpe/defaults/main.yml`)

Part of the iPXE project; the same attribution requirement applies.

### VirtIO drivers for Windows (`virtio-win`)

- **Project:** <https://fedorapeople.org/groups/virt/virtio-win/>
- **Source:** <https://github.com/virtio-win/kvm-guest-drivers-windows>
- **Licence:** BSD-3-Clause for the drivers; GPL-2.0 for some tools. The
  ISO also contains the QEMU guest agent (GPL-2.0).
- **Used for:** Storage (`viostor`), network (`NetKVM`), balloon and
  serial drivers, without which Windows Setup sees no disk and the
  installed host has no network.
- **Obtained from:** The Fedora `virtio-win` archive, at deployment
  time.

These drivers run in **kernel mode** on the Windows target. The
configuration supports pinning the ISO's SHA-256, and the role prints
the observed digest when it is not pinned.

### Ubuntu Server

- **Publisher:** Canonical Ltd.
- **Source:** <https://releases.ubuntu.com/24.04/>
- **Licence:** Individual packages under their own licences (GPL, MIT,
  BSD, Apache and others). See
  <https://ubuntu.com/legal/intellectual-property-policy>.
- **Obtained from:** `releases.ubuntu.com`, at deployment time,
  verified against the official `SHA256SUMS`.

---

## Container images

Pulled at deployment time; none is redistributed here.

| Image | Version | Licence | Project |
|---|---|---|---|
| `postgres` | `16.4-alpine3.20` | PostgreSQL Licence (permissive, BSD-like) | <https://www.postgresql.org> |
| `gitea/gitea` | `1.22.6-rootless` | MIT | <https://gitea.com> |
| `semaphoreui/semaphore` | `v2.10.34` | MIT | <https://semaphoreui.com> |
| `nginx` | `1.27.2-alpine3.20` | BSD-2-Clause | <https://nginx.org> |
| `python` | `3.12.7-alpine3.20` | PSF Licence | <https://www.python.org> |
| `alpine` | `3.20.3` | MIT (base); packages under their own | <https://alpinelinux.org> |

### Images built from this repository

| Image | Base | Contents |
|---|---|---|
| `forge-ai/state` | `python:3.12.7-alpine3.20` | `compose/state-service/app.py` — Apache-2.0, standard library only |
| `forge-ai/webhook` | `python:3.12.7-alpine3.20` | `compose/webhook/app.py` — Apache-2.0, standard library only |
| `forge-ai/winmedia` | `alpine:3.20.3` | Samba, configured by `compose/samba/smb.conf` |

Neither Python service has any dependency beyond the standard library,
so their dependency surface is the base image and nothing else.

**Samba** — GPL-3.0-or-later — <https://www.samba.org>. Used read-only
and anonymously, to serve `install.wim` to WinPE, which cannot mount
HTTP.

---

## Host packages

Installed from the Ubuntu archive by `bootstrap/prepare-host.sh`, under
their own licences.

| Package | Licence | Used for |
|---|---|---|
| `qemu-kvm`, `qemu-utils` | GPL-2.0 | Virtualisation |
| `libvirt-daemon-system`, `libvirt-clients` | LGPL-2.1+ | VM lifecycle |
| `virtinst` | GPL-2.0+ | VM creation |
| `ovmf` | BSD-2-Clause-Patent | UEFI firmware for the guests |
| `dnsmasq` | GPL-2.0 or GPL-3.0 | DHCP, DNS, TFTP |
| `ipxe`, `ipxe-qemu` | GPL-2.0+ with UBDL | Network boot (see above) |
| `p7zip-full` | LGPL-2.1+ | Reading ISO images without a loop mount |
| `wimtools` (wimlib) | LGPL-3.0+ | **Reading and editing WIM images on Linux** — what removes the need for DISM and a Windows machine |
| `tcpdump` | BSD-3-Clause | The DHCP conflict probe |
| `smbclient` | GPL-3.0+ | Verifying the media export |
| `libxml2-utils` | MIT | `xmllint`, for validating `Autounattend.xml` |
| `whois` | GPL-2.0+ | `mkpasswd`, for the autoinstall password hash |
| `openssl` | Apache-2.0 | TLS material |
| `jq` | MIT | JSON in shell |
| `curl` | curl licence (MIT-like) | Downloads and probes |

---

## Ansible collections

Installed by `ansible-galaxy` or bundled with the `ansible` PyPI
distribution.

| Collection | Licence | Used for |
|---|---|---|
| `ansible.posix` | GPL-3.0-or-later | `authorized_key`, `sysctl` |
| `ansible.windows` | GPL-3.0-or-later | Windows modules |
| `community.windows` | GPL-3.0-or-later | Windows extras |
| `community.general` | GPL-3.0-or-later | `ufw`, `timezone`, `json_query` |
| `community.libvirt` | GPL-3.0-or-later | Domain and network lifecycle |
| `community.docker` | GPL-3.0-or-later | Compose orchestration |
| `community.crypto` | GPL-3.0-or-later | TLS material |

**ansible-core** itself is GPL-3.0-or-later —
<https://github.com/ansible/ansible>.

### A note on GPL and Apache-2.0

This repository is Apache-2.0. It **uses** GPL-licensed tools by
executing them; it does not link against them or incorporate their
source. Ansible playbooks and roles are data consumed by ansible-core,
not derivative works of it — the same relationship a shell script has
with `bash`.

If you vendor GPL source into a derivative of this project, the GPL
terms attach to that part.

---

## Python libraries

| Library | Licence | Used by |
|---|---|---|
| `Jinja2` | BSD-3-Clause | Template rendering |
| `PyYAML` | MIT | Configuration parsing |
| `jsonschema` | MIT | Schema validation |
| `pywinrm` | MIT | The WinRM transport |
| `pypsrp` | MIT | The PSRP transport |
| `libvirt-python` | LGPL-2.1+ | libvirt bindings |
| `pytest` | MIT | Tests |
| `ansible-lint` | GPL-3.0+ | Linting |
| `yamllint` | GPL-3.0+ | Linting |
| `molecule` | MIT | Role testing |
| `lxml` | BSD-3-Clause | XML validation |

---

## Development tooling

| Tool | Licence |
|---|---|
| ShellCheck | GPL-3.0 |
| bats-core | MIT |
| markdownlint-cli | MIT |
| Trivy | Apache-2.0 |
| Gitleaks | MIT |
| Mermaid (diagram syntax) | MIT |

---

## Microsoft software

**Nothing from Microsoft is distributed by this repository.**

No ISO. No `boot.wim`. No `install.wim`. No ADK component. No product
key. No redistributable.

The operator obtains Windows Server media themselves, from the Microsoft
Evaluation Center or their own licensing channel, and accepts
Microsoft's terms directly. This project is not a party to that
agreement and grants no rights to Microsoft software.

What this project does with that media, entirely on the operator's own
host:

- verifies its SHA-256 and records it in the deployment report;
- reads its `install.wim` metadata with `wimlib-imagex` to list the
  editions it contains;
- extracts its contents for local network installation;
- injects VirtIO drivers into a **copy** of its `boot.wim`.

All of that is ordinary use of media the operator already holds a
licence for. None of it is redistribution.

**Windows activation is explicitly out of scope.** Evaluation media
installs unkeyed and runs for its evaluation period. The configuration
schema enforces `media.windows.product_key` as **empty**, so a key
cannot be committed even by accident.

---

## Reporting an attribution problem

If a component is missing here, attributed incorrectly, or its licence
has changed, please open an issue or a pull request. Getting this right
matters more than getting it quickly.
