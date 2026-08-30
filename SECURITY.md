# Security policy

## Reporting a vulnerability

**Please report privately**, through GitHub Security Advisories:

<https://github.com/danielesalpietro/FORGE-AI/security/advisories/new>

Do **not** open a public issue for a security problem.

### What helps

- What the flaw is, and which component it affects
- How to reproduce it
- What an attacker could achieve
- The version or commit you found it in

### What to expect

This is a personal proof-of-concept project, not a commercial product
with a support contract. Expect an acknowledgement within a few days and
an honest answer about whether and when it will be fixed.

---

## Before reporting: is it already documented?

This is a **proof of concept**, and several controls a production
deployment would require are **deliberately documented rather than
implemented**. [`docs/SECURITY.md`](docs/SECURITY.md) sets out a
fourteen-item threat model, and for each threat states the PoC
mitigation, the production recommendation and **what remains
unmitigated**.

Known and documented, among others:

| Documented residual risk |
|---|
| Secure Boot is off; the boot chain is unsigned |
| The boot server does not authenticate reads — a PXE ROM has no credential to present |
| `Autounattend.xml` carries a reversibly-encoded administrator password during installation |
| WinRM uses a self-signed certificate, so certificate validation defaults to off |
| One shared local administrator password, because a workgroup has no Kerberos and no LAPS |
| Media digests are verified; the GPG signature on `SHA256SUMS` is not |
| Secrets are long-lived, with manual rotation |
| No replay protection on the webhook |

A report that restates one of these is still welcome — **especially if
the documentation is wrong, understates the impact, or the stated
mitigation does not actually work.** That is genuinely useful.

What is most valuable is a flaw that is **not** on that list, or a case
where a control this project claims to have does not hold.

---

## Scope

### In scope

- The code in this repository: playbooks, roles, templates, scripts, the
  state service, the webhook receiver
- The container images built here (`compose/state-service`,
  `compose/webhook`, `compose/samba`)
- The default configuration in `config/defaults.yml` and
  `config/poc.example.yml`
- The CI workflows
- Documentation that **understates** a risk

### Out of scope

- Vulnerabilities in upstream projects — report those to Gitea,
  Semaphore, Ansible, iPXE, dnsmasq, libvirt or Docker directly
- The documented residual risks above, unless the documentation is wrong
- Issues that require an attacker to already have root on the KVM host
- Anything in Microsoft software; this project distributes none of it
- Configuration mistakes an operator makes in their own
  `config/poc.yml`, unless validation should have caught it and did not

---

## Deploying this safely

If you are running this anywhere that matters, read
[`docs/SECURITY.md`](docs/SECURITY.md) first. The essentials:

1. **Never put the provisioning network on a production LAN.** This
   project runs a DHCP server. `make check` probes for a conflict before
   creating anything; do not skip it or override it casually.
2. **Treat the generated secrets as proof-of-concept credentials.** They
   are strong and correctly permissioned, but they are long-lived and
   rotation is manual.
3. **The provisioning segment is a trust boundary.** Anything on it can
   read every boot artefact, including the answer files, for as long as
   they exist.
4. **Understand what is not enabled.** Secure Boot, certificate
   validation for WinRM, Kerberos, LAPS.
5. **Keep the audit trail.** Deployment reports and Semaphore task
   history are the record of what was done. No destroy target removes
   the reports.

---

## Supported versions

| Version | Supported |
|---|---|
| `main` | Yes |
| Latest release | Yes |
| Older releases | No |

Fix forward: report against `main` or the latest release.

---

## Security controls in CI

Every pull request runs, and **fails on**:

- Secret scanning across the full history (Gitleaks) and the project's
  own hygiene tests — which are themselves tested against *planted*
  secrets, because a check that always passes protects nothing
- Rejection of committed ISO, WIM, ESD, disk image, private key,
  certificate, vault or product-key files
- Rejection of the operator's own `compose/.env` and `config/poc.yml`
- Confirmation that the Windows answer file never emits `PlainText=true`
- Confirmation that the Ubuntu seed uses a password hash
- Rejection of any script that disables TLS validation without a named,
  visible control
- Rejection of any privileged container or `:latest` image tag
- Confirmation that every required secret uses `${VAR:?message}`, so the
  stack fails fast rather than starting with an empty password
- Trivy filesystem, configuration and container image scans
- Dependency review

These are enforcement, not convenience. `.gitignore` is a convenience.
