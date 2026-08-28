# References

The official documentation this implementation was built against, and
what each source actually settled.

> Everything here is a primary source: project documentation, vendor
> documentation or a specification. Where behaviour was uncertain, the
> question was resolved against these rather than against a blog post,
> and the answer is recorded below so it can be re-checked when a
> version moves.

---

## Ansible

### Windows and WinRM

- **Windows Remote Management** —
  <https://docs.ansible.com/ansible/latest/os_guide/windows_winrm.html>
- **Setting up a Windows host** —
  <https://docs.ansible.com/ansible/latest/os_guide/windows_setup.html>
- **`ansible.windows` collection** —
  <https://docs.ansible.com/ansible/latest/collections/ansible/windows/>
- **`community.windows` collection** —
  <https://docs.ansible.com/ansible/latest/collections/community/windows/>

**Settled:** that `ansible_winrm_transport: ntlm` over HTTPS is the
correct choice for a workgroup host, and that Kerberos is the
domain-integrated evolution. Confirmed the connection variables —
`ansible_winrm_scheme`, `ansible_winrm_server_cert_validation`,
`ansible_winrm_read_timeout_sec` — and that CredSSP requires
`pywinrm[credssp]`, which is why it is deliberately not installed.

Also settled which modules moved to `ansible.windows` as their canonical
home: `win_firewall` and `win_audit_policy_system` are there, not in
`community.windows`. `ansible-lint`'s `fqcn[canonical]` rule caught the
wrong ones and this documentation confirmed the correction.

### Check mode

- **Validating tasks: check mode and diff mode** —
  <https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_checkmode.html>

**Settled:** that check-mode support is per-module and not universal.
This is the source for the honest position in `docs/OPERATIONS.md`:
`win_shell` and `win_command` have no check-mode support at all, which
is why every control also has a read-only compliance probe.

### Configuration

- **Ansible configuration settings** —
  <https://docs.ansible.com/ansible/latest/reference_appendices/config.html>

**Settled:** that `DEFAULT_UNDEFINED_VAR_BEHAVIOR` is deprecated in
ansible-core 2.19 and scheduled for removal in 2.23, because erroring on
an undefined variable has been the default for years. That is why
`ansible.cfg` does **not** set `error_on_undefined_vars` — setting it
buys nothing and emits a deprecation warning on every run.

Also confirmed that `[ssh_connection]` is a connection-plugin section,
which `ansible-config validate` reports as "unknown" while the settings
are genuinely applied — noted in `ansible.cfg` so nobody "fixes" a
non-problem.

### `community.libvirt`

- <https://docs.ansible.com/ansible/latest/collections/community/libvirt/>

**Settled:** the `virt`, `virt_net` and `virt_pool` module semantics —
in particular that `command: define` is separate from `state: active`,
and that `list_nets` is the way to check for an existing network without
an error.

---

## Semaphore UI

- **Documentation** — <https://docs.semaphoreui.com/>
- **Installation** — <https://docs.semaphoreui.com/administration-guide/installation/>
- **API reference** — <https://docs.semaphoreui.com/administration-guide/api/>
- **Environment and secrets** —
  <https://docs.semaphoreui.com/user-guide/environment/>

**Settled:**

- The API shape used by `semaphore_config`: `/api/auth/login`,
  `/api/user/tokens`, `/api/projects`, and the per-project
  `keys`, `repositories`, `inventory`, `environment`, `templates` and
  `tasks` endpoints.
- That `SEMAPHORE_ACCESS_KEY_ENCRYPTION` must be **exactly 32 raw
  bytes, base64-encoded**. A different length makes Semaphore restart in
  a loop with an error that does not say so — recorded in
  `docs/SEMAPHORE-SETUP.md`.
- That the **environment is stored as plain JSON** while the Key Store
  is encrypted at rest. This is the whole basis of the "where secrets
  live" table in `docs/SECURITY.md`, and why
  `environment.json.j2` carries no credentials and says so.
- That survey variables are a UI control on the template, which is why
  `destroy-poc.yml` asserts the confirmation token independently.

---

## Gitea

- **Documentation** — <https://docs.gitea.com/>
- **Webhooks** — <https://docs.gitea.com/usage/webhooks>
- **Repository mirroring** — <https://docs.gitea.com/usage/repo-mirror>
- **API (Swagger)** — <https://docs.gitea.com/api/1.20/>
- **Configuration cheat sheet** —
  <https://docs.gitea.com/administration/config-cheat-sheet>

**Settled:**

- That Gitea signs webhook payloads with **HMAC-SHA256 over the raw
  body**, sending the hex digest in `X-Gitea-Signature`. This is why
  `compose/webhook/app.py` verifies before parsing, and why the proxy
  configuration must not rewrite or buffer the body.
- The **pull-mirror** semantics used by the default `sync_strategy`:
  `POST /repos/migrate` with `mirror: true` and `mirror_interval`. This
  is what makes it possible for GitHub to hold no Gitea credential at
  all.
- The `GITEA__section__KEY` environment-variable convention used
  throughout `docker-compose.yml`, including the `cron_2E_` escaping for
  a section name containing a dot.
- The `gitea admin user generate-access-token` scopes, and that a token
  value is shown **once** — recorded in the role's error message,
  because it is not obvious and the recovery is to delete and recreate.

---

## Ubuntu

### Subiquity autoinstall

- **Automated Server installer** —
  <https://canonical-subiquity.readthedocs-hosted.com/en/latest/>
- **Autoinstall reference** —
  <https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html>
- **Autoinstall schema** —
  <https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-schema.html>

**Settled:** the complete answer-file structure — `version: 1`,
`interactive-sections`, the `storage.config` action list, `identity`,
`ssh`, `late-commands`, `error-commands`. Confirmed that
`interactive-sections: []` is what makes a run fully unattended, and
that `late-commands` execute with the target mounted at `/target`.

### cloud-init NoCloud

- **NoCloud datasource** —
  <https://docs.cloud-init.io/en/latest/reference/datasources/nocloud.html>
- **Kernel command line** —
  <https://docs.cloud-init.io/en/latest/reference/cli.html>

**Settled: the trailing slash.** cloud-init appends the filenames to the
`s=` value verbatim, so `s=http://…/poc-ubuntu-01` requests
`…poc-ubuntu-01user-data`. This documentation is the reason the iPXE
template builds the URL with an explicit trailing slash and a test
asserts it.

Also settled that `nocloud-net` is deprecated in favour of `nocloud`
with an HTTP `seedfrom`, and from which cloud-init version — which is
why `docs/COMPATIBILITY.md` notes that 22.04 needs the older spelling.

### Netboot

- **Ubuntu netboot** —
  <https://help.ubuntu.com/community/Installation/QuickNetboot>
- **Ubuntu releases** — <https://releases.ubuntu.com/24.04/>

**Settled:** that there is **no `netboot.tar.gz` for 24.04 Server**, and
that the supported path is booting the live-server kernel and initrd
with `url=` pointing at the ISO. This shapes the whole `ubuntu_media`
role, and `releases.ubuntu.com` is where `SHA256SUMS` is fetched from
when no checksum is pinned.

---

## Microsoft

> Consulted for behaviour only. **No Microsoft content, media or binary
> is reproduced or redistributed by this repository.**

### Unattended installation

- **Unattended Windows Setup Reference** —
  <https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/>
- **Windows Setup configuration passes** —
  <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-configuration-passes>
- **Windows Setup command-line options** —
  <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/windows-setup-command-line-options>
- **`Microsoft-Windows-Setup` DiskConfiguration** —
  <https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-setup-diskconfiguration>

**Settled:**

- That `setup.exe /unattend:<file>` **does** process the `windowsPE`
  pass, which is what makes the WinPE-launched flow work at all.
- The UEFI/GPT partition layout Setup expects: EFI, MSR, Primary — and
  that the Windows partition is `PartitionID` 3.
- The `AdministratorPassword` encoding when `PlainText` is `false`:
  **Base64 of UTF-16LE(password + the element name)**. Getting the
  element name wrong leaves the account with no password, which is why
  `win_unattend_password` validates the field name and a test
  round-trips it.
- That `SetupComplete.cmd` in `%WINDIR%\Setup\Scripts\` runs **once, as
  SYSTEM**, after the last reboot and before the first logon.
- The OOBE suppression elements needed for a genuinely unattended
  install.

### Evaluation media

- **Microsoft Evaluation Center** — <https://www.microsoft.com/evalcenter>

**Settled:** that evaluation media is the operator's to obtain under
Microsoft's terms — the basis for the acquisition procedure in
`docs/WINDOWS-PROVISIONING.md` and for this project shipping none of it.

### WinRM

- **Windows Remote Management** —
  <https://learn.microsoft.com/en-us/windows/win32/winrm/portal>
- **Installation and configuration** —
  <https://learn.microsoft.com/en-us/windows/win32/winrm/installation-and-configuration-for-windows-remote-management>

**Settled:** the `WSMan:\localhost\` configuration tree used by
`Configure-WinRM.ps1` — `Service\Auth\*`, `Service\AllowUnencrypted`,
`Shell\MaxMemoryPerShellMB` — and the `New-Item -Path
WSMan:\localhost\Listener` parameters for an HTTPS listener.

### Windows LAPS

- <https://learn.microsoft.com/en-us/windows-server/identity/laps/laps-overview>

**Settled:** that LAPS requires **Entra ID or Active Directory** to
store the rotated password. That is why this PoC reports LAPS readiness
rather than configuring it, and why `docs/SECURITY.md` describes the
shared local administrator as a residual risk rather than a fixable one
in a workgroup.

### DISM

- <https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14>

**Settled:** the WIM image-index semantics — that a `boot.wim` contains
"Microsoft Windows PE" and "Microsoft Windows Setup", and an
`install.wim` contains one image per edition. This is the basis for
selecting by **name** rather than index in both places.

---

## iPXE

- **Documentation** — <https://ipxe.org/docs>
- **Command reference** — <https://ipxe.org/cmd>
- **Scripting** — <https://ipxe.org/scripting>
- **Settings and expansions** — <https://ipxe.org/cfg>
- **Chainloading** — <https://ipxe.org/howto/chainloading>
- **wimboot** — <https://ipxe.org/wimboot>
- **Booting Windows** — <https://ipxe.org/howto/winpe>

**Settled:**

- **The chainload loop and how to prevent it.** iPXE identifies itself
  with DHCP option 175 and user class `iPXE`; the documented remedy is
  to make every "serve a binary" rule conditional on the client *not*
  being iPXE. This is the entire basis of the `tag:!ipxe` arrangement in
  the dnsmasq template.
- `${mac:hexhyp}` expansion, which is why per-host state files and boot
  scripts are named with hyphen-separated MACs — and why the dnsmasq
  `set:` tag uses the same form.
- **wimboot's file-injection behaviour**: any file beyond
  `bootmgr`/`BCD`/`boot.sdi`/`*.wim` is injected into
  `\Windows\System32` of the booted image. This is what makes it
  possible to deliver a per-host `Autounattend.xml` without ever writing
  it to the shared SMB export.
- Plain `exit` (not `sanboot --drive 0x80`, a BIOS/legacy INT13 trick
  that fails with "No such device" on these UEFI guests) as the
  local-disk fallback: it returns control to firmware, which then
  proceeds to the domain's own next boot option.

---

## dnsmasq

- **Manual page** — <https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html>
- **Setup notes** — <https://thekelleys.org.uk/dnsmasq/docs/setup.html>

**Settled:** the `dhcp-match`, `dhcp-userclass`, `dhcp-boot` and
`dhcp-host` syntax, including tag negation (`tag:!ipxe`) and multiple
tags on one rule. Also confirmed `bind-dynamic` versus `bind-interfaces`
— the former copes with the libvirt bridge being recreated, which
matters because libvirt owns that device.

### RFC 4578 — DHCP options for PXE

- <https://www.rfc-editor.org/rfc/rfc4578>

**Settled:** the option 93 client-architecture values used for
architecture-aware boot: `0` legacy BIOS, `6` EFI IA32, `7` and `9` EFI
x86-64, `16` EFI x86-64 HTTP Boot. Also that HTTP Boot clients expect
vendor class `HTTPClient` in option 60, which is why the template forces
it.

---

## libvirt

- **Network XML format** — <https://libvirt.org/formatnetwork.html>
- **Domain XML format** — <https://libvirt.org/formatdomain.html>
- **Networking** — <https://wiki.libvirt.org/Networking.html>

**Settled:** that libvirt spawns its own dnsmasq **only** when a network
needs DHCP or DNS. With `<dns enable="no"/>` and no `<dhcp>` element it
creates the bridge and the NAT rules and stops — which is exactly what
lets FORGE-AI run its own dnsmasq without two DHCP servers fighting over
one bridge.

Also settled the `<boot dev=…/>` ordering semantics, the `firmware="efi"`
and `<feature name="secure-boot"/>` attributes, and the Hyper-V
enlightenments applied to Windows guests.

---

## Docker

- **Compose specification** — <https://docs.docker.com/reference/compose-file/>
- **`depends_on`** —
  <https://docs.docker.com/reference/compose-file/services/#depends_on>
- **Profiles** — <https://docs.docker.com/compose/how-tos/profiles/>
- **`postgres` image** — <https://hub.docker.com/_/postgres>

**Settled:** the `${VAR:?message}` interpolation form that makes a
missing secret fail fast with a usable message, the
`condition: service_healthy` dependency form, `profiles` for the
optional Windows SMB service, and that `deploy.resources.limits` is
honoured by Compose v2 outside Swarm.

Also the `docker-entrypoint-initdb.d` hook semantics: it runs **only**
on an empty data directory, which is why the database bootstrap script
is written to be re-runnable anyway.

---

## Standards

| Specification | Used for |
|---|---|
| [RFC 4578](https://www.rfc-editor.org/rfc/rfc4578) | DHCP PXE options, especially option 93 |
| [RFC 2131](https://www.rfc-editor.org/rfc/rfc2131) | DHCP |
| [RFC 1350](https://www.rfc-editor.org/rfc/rfc1350) | TFTP — and why it is unsuitable for large transfers |
| [JSON Schema 2020-12](https://json-schema.org/draft/2020-12/release-notes) | `config/schema/poc.schema.json` |
| [Semantic Versioning 2.0.0](https://semver.org/) | Release tags |
| [Conventional Commits 1.0.0](https://www.conventionalcommits.org/) | Commit messages and the changelog |
| [Keep a Changelog 1.1.0](https://keepachangelog.com/) | `CHANGELOG.md` |

---

## Guidance consulted, not implemented

Referenced in the security documentation as the direction a production
deployment would take:

- **CIS Ubuntu Linux Benchmark** — <https://www.cisecurity.org/benchmark/ubuntu_linux>
  The `cis-demo.yml` tasks are *informed by* it. This is **not** a
  benchmark run and `docs/LIMITATIONS.md` says so.
- **CIS Microsoft Windows Server Benchmark** —
  <https://www.cisecurity.org/benchmark/microsoft_windows_server>
- **NIST SP 800-53 Rev. 5** —
  <https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final>
- **UEFI Specification** — <https://uefi.org/specifications> — for the
  Secure Boot discussion in `docs/SECURITY.md`.
