# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

Nothing yet.

---

## [1.0.0] - 2026-08-27

The initial proof of concept: a complete GitOps provisioning platform
that takes two virtual machines from bare disk to operational.

### Added

#### Configuration and validation

- `config/defaults.yml` and `config/poc.example.yml` as the single
  declarative desired state — names, addressing, resources and baseline
  policy in one file.
- JSON Schema (`config/schema/poc.schema.json`) with
  `additionalProperties: false` throughout, so a typo in a key name is
  rejected rather than ignored.
- A semantic validator for the rules a schema cannot express: duplicate
  MAC and IP addresses, CIDR membership, DHCP pool overlap, a gateway
  that disagrees with the control-plane address, non-locally-administered
  MACs, and plaintext secrets in configuration.
- A dynamic Ansible inventory that **refuses to build** from an invalid
  configuration, so an invalid desired state cannot reach a target.

#### Control plane

- Docker Compose stack: Gitea, Semaphore, PostgreSQL, a TLS proxy, a
  boot artefact server, a provisioning state service, an HMAC-validating
  webhook receiver, and a read-only SMB export for Windows media.
- Every required secret uses `${VAR:?message}`, so the stack fails fast
  with a usable message rather than starting with an empty password.
- Per-application database roles, health checks, resource limits, log
  rotation, `no-new-privileges` and read-only root filesystems where
  possible.

#### Boot chain

- Architecture-aware PXE via dnsmasq: DHCP option 93 for BIOS, EFI IA32,
  EFI x86-64 and UEFI HTTP Boot.
- **Chainload-loop prevention** by construction: every rule that hands
  over a binary carries `tag:!ipxe`, so iPXE can never be told to load
  iPXE.
- A **reinstall-loop guard**: the state service increments an attempt
  counter on every dispatch and stops offering the installer past the
  limit, parking the host as `failed` rather than reinstalling forever.
- libvirt boot order flipped to local disk after installation as a
  second, independent guard.
- A dedicated dnsmasq instance bound only to the libvirt bridge, so
  FORGE-AI never changes the behaviour of a dnsmasq the host already
  runs.

#### Ubuntu provisioning

- Subiquity autoinstall over PXE, with the seed generated from the
  desired state.
- A crypt(3) password hash — never a cleartext password — asserted for
  format before rendering.
- Installer callbacks that report `installed` or `failed`, and upload
  `/var/log/installer` on failure.
- The seed is purged after installation, leaving a record of the
  exposure window.

#### Windows provisioning

- WinPE over wimboot, with per-host `startnet.cmd` and
  `Autounattend.xml` injected into `\Windows\System32` — so the answer
  file, which carries the administrator password, never touches the
  shared SMB export.
- **VirtIO driver injection on Linux** using `wimlib-imagex`: no DISM,
  no Windows machine, no ADK.
- Edition selection **by name**, validated against the WIM metadata
  before any installation starts, because index 1 on a Server ISO is
  normally Server Core.
- WinRM over HTTPS configured during `SetupComplete.cmd`, with Basic and
  CredSSP disabled and the firewall scoped to the management network.

#### Configuration and verification

- Ubuntu and Windows baseline roles, written to be **check-mode safe**
  because the same roles run under `--check` for drift detection.
- Read-only compliance probes alongside check mode, because
  `win_shell` and `win_updates` have no check-mode support at all.
- `forge-health`, a single command that answers "is this host in the
  state FORGE-AI intended?".
- Deployment reports in JSON, Markdown and HTML, assembled from
  cacheable facts so they can describe a run that **partially failed**.

#### Drift

- Detection from two independent sources, with every finding labelled by
  source and the blind spots recorded in the report.
- Reconciliation as a separate, manual step that **re-runs detection
  afterwards and fails if drift survives**.

#### Safety

- Three independent confirmations before destruction: the Makefile, the
  script, and the playbook — because a UI control is not a security
  boundary.
- A passive DHCP-conflict probe before the network is created.
- Deployment reports are never removed by any destroy target.

#### Testing and CI

- 204 unit tests and 29 shell tests, none of which need a hypervisor.
- A coverage guard that fails when a template has no rendering test.
- A secret detector tested against **planted** secrets, not only a clean
  tree.
- Negative tests in CI: if duplicate MAC/IP detection stops working, the
  build fails rather than passing everything through.
- `ansible-lint` at the **production** profile with zero findings.
- A self-hosted KVM end-to-end workflow, **disabled rather than
  deleted**, so the documented coverage gap stays checkable.

#### Documentation

- Thirteen documents covering architecture, quickstart, both
  provisioning paths, GitOps workflow, Semaphore setup, operations,
  security, troubleshooting, limitations, a demonstration runbook,
  tested versions, and the official references each decision was
  checked against.

### Security

- No Microsoft media, binary or product key is distributed. The schema
  enforces `product_key` as empty so one cannot be committed.
- Secrets are written with their mode set **before** content, so there
  is no window in which they are world-readable.
- Ansible Vault for operator-run tasks, the Semaphore Key Store for
  Semaphore-run tasks, and an explicit note that the Semaphore
  *environment* is plain JSON and is not a secret store.
- A fourteen-item threat model, each with its PoC mitigation, production
  recommendation and **residual risk**.

### Known limitations

Documented in full in `docs/LIMITATIONS.md`. In summary: Secure Boot is
off, WinRM uses a self-signed certificate, there is one shared local
administrator password because a workgroup has no Kerberos or LAPS,
check-mode coverage is incomplete and this is stated rather than hidden,
CI cannot deploy, and the "CIS-inspired" controls are not a CIS
benchmark run.

---

[Unreleased]: https://github.com/danielesalpietro/FORGE-AI/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/danielesalpietro/FORGE-AI/releases/tag/v1.0.0
