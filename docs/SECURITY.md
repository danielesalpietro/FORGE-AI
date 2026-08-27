# Security

The threat model, what this proof of concept does about each threat, and
what it does **not**.

> **Read this first.** This is a PoC. Several controls a production
> deployment would require are documented here rather than implemented,
> and that distinction is made explicitly for every one of them. A PoC
> that pretends to be production-ready is worse than one that is honest
> about where the line is.

---

## Trust boundaries

```text
┌─ Internet ────────────────────────────────────────────────────────┐
│  GitHub · Ubuntu archive · container registries · virtio-win       │
└────────────────────────────┬───────────────────────────────────────┘
                             │  outbound only, TLS, checksums verified
┌─ KVM host ─────────────────┴───────────────────────────────────────┐
│                                                                    │
│  ┌─ loopback ──────────────┐   ┌─ provisioning bridge ───────────┐ │
│  │ Gitea, Semaphore        │   │ boot server :8080               │ │
│  │ PostgreSQL              │   │ SMB export  :445                │ │
│  │ TLS, authenticated      │   │ dnsmasq     :67, :69            │ │
│  └─────────────────────────┘   │                                 │ │
│                                │  NO authentication on GET       │ │
│  Ansible Vault (0600)          │  answer files served here       │ │
│  compose/.env (0600)           └────────────┬────────────────────┘ │
└─────────────────────────────────────────────┼──────────────────────┘
                                              │
                                    poc-ubuntu-01, poc-windows-01
```

The provisioning bridge is the soft boundary and is treated as such
throughout: **anything on it can read every boot artefact, including the
answer files, for as long as they exist.** The mitigations are isolation
and a short exposure window, not access control — a PXE ROM cannot
present a credential.

---

## Threat model

Each threat states the risk, what this PoC does, what production should
do instead, and **what remains**.

---

### 1. Rogue DHCP server on the provisioning segment

**Risk.** An attacker answering DHCP faster than dnsmasq redirects a
booting machine to a boot server they control, and owns it before any
operating system exists.

**PoC mitigation.** The segment is an isolated libvirt bridge with only
the two target VMs on it. `dhcp-authoritative` makes dnsmasq answer
immediately. Before creating anything, `check-prerequisites.sh` and the
`prerequisite_validation` role run a **passive** capture for competing
DHCP traffic and refuse to proceed if they see any.

**Production.** DHCP snooping on the switch, with trusted ports only.
802.1X on the provisioning VLAN. Separate the provisioning VLAN from
everything else at layer 2.

**Residual.** Anyone with hypervisor access can attach an interface to
the bridge. The probe is passive, so it only sees a rogue server that is
actively answering *during the capture window*.

---

### 2. FORGE-AI itself as a rogue DHCP server

**Risk.** This is the threat the project poses to *you*. A misconfigured
`provisioning_network` puts a DHCP server on a production LAN, handing
addresses to machines that have nothing to do with the PoC. The failure
is intermittent, so it gets blamed on everything except DHCP.

**PoC mitigation.** dnsmasq runs as a **dedicated systemd unit** bound
to the libvirt bridge alone — `interface=`, `listen-address=`,
`bind-dynamic`. A drop-in under `/etc/dnsmasq.d/` would have changed the
behaviour of whatever dnsmasq the host already runs, so the packaged
service is stopped and **the role says so in its output**. The libvirt
network is defined with no DHCP, and the role fails if libvirt started
its own dnsmasq anyway. `make validate` rejects a configuration whose
addressing looks wrong.

**Production.** A physically or logically separate provisioning network.
Never on a shared LAN.

**Residual.** An operator who deliberately points
`provisioning_network` at a production subnet and overrides the conflict
check with `-e forge_force=true` will succeed in causing exactly this.

---

### 3. Malicious PXE or boot server

**Risk.** The boot server serves unauthenticated content to machines
that will execute it as the first code they run.

**PoC mitigation.** The boot server binds only to the bridge address.
nginx returns **404 for anything not explicitly exposed**, so a
directory listing cannot leak the answer files. The state service
requires a shared token on every *mutating* endpoint.

**Production.** HTTPS boot with a certificate the firmware trusts.
Signed iPXE images with `imgtrust`. UEFI Secure Boot with an enrolled
key. Attest the boot chain before releasing credentials.

**Residual.** **GET is unauthenticated and cannot be otherwise** — a PXE
ROM has no credential to present. Anything on the bridge can read the
boot scripts and, during the exposure window, the answer files.

---

### 4. Answer-file credential exposure

**Risk.** An unattended installer must authenticate before any secret
store exists. Both answer files therefore carry credentials on the
network.

**PoC mitigation.**

| Artefact | Carries | Mitigation |
|---|---|---|
| Ubuntu seed | A **crypt(3) hash** (yescrypt or SHA-512) | Never cleartext. The role asserts the hash format before rendering. Purged once the host reports `installed`. |
| `Autounattend.xml` | Base64(UTF-16LE(password + field name)) | **Never written to the SMB share** — wimboot injects it straight into WinPE's `\Windows\System32`. Purged after install, with a `PURGED.txt` recording the window. |

The Windows encoding is what Microsoft calls "encrypted" when
`PlainText` is `false`. **It is reversible by anyone holding the file.**
This repository calls it obfuscation and tests that the cleartext
password never appears in the rendered file.

**Production.** Inject credentials at first boot from a secret manager
over an authenticated channel. Use a one-time bootstrap credential that
is revoked the moment configuration management takes over. Windows LAPS
for the local administrator.

**Residual.** The exposure window is real: from render to installation
complete, anything on the provisioning bridge can read
`Autounattend.xml` and recover the administrator password. Setting
`security.purge_answer_files_after_install: false` extends that window
indefinitely.

---

### 5. Compromised Git account or malicious pull request

**Risk.** This is a GitOps system: whoever controls the repository
controls the infrastructure. A malicious change to a playbook or an
answer file runs with root on every target.

**PoC mitigation.** Semaphore reads **Gitea**, which mirrors `main`.
Nothing on a feature branch can reach a machine. The webhook receiver
enforces a branch filter *and* verifies HMAC before parsing. CODEOWNERS
requires review on the security-relevant paths — the boot chain, the
answer files, the secrets script, CI. CI runs secret scanning, Trivy and
the project's own hygiene tests on every pull request.

**Production.** Require signed commits and a signed tag for release.
Two-person review on infrastructure paths. Hardware-backed 2FA on every
account with write access. A separate, more privileged approval for
anything touching the boot chain.

**Residual.** A reviewer who approves a malicious change defeats all of
it. CI checks *patterns*, not *intent*: it will not notice a plausible
but wrong firewall rule.

---

### 6. Gitea token theft

**Risk.** A stolen Gitea token can push to the GitOps repository, which
is what Semaphore deploys.

**PoC mitigation.** The token is scoped to `write:organization` and
`write:repository` — **not** `sudo`. It lives in Ansible Vault,
encrypted at rest. With the default `mirror` strategy the Gitea
repository is a **pull mirror**, so a push to it is overwritten on the
next sync and GitHub holds no Gitea credential at all.

**Production.** Short-lived tokens. A dedicated service account with no
interactive login. Audit log shipping. Consider signed commits, so a
token alone is not enough to introduce a change.

**Residual.** The token is long-lived. Rotation is manual (see
[Rotation](#rotating-a-credential)). With `sync_strategy: push`, a Gitea
credential does live in GitHub Actions secrets — that is the documented
trade-off for immediate propagation.

---

### 7. Webhook forgery

**Risk.** An unverified webhook is an unauthenticated "please deploy
this" endpoint.

**PoC mitigation.** `compose/webhook/app.py` verifies **HMAC-SHA256 over
the raw body, using `hmac.compare_digest`, before parsing anything**. An
empty secret rejects every request rather than accepting all of them.
The receiver is not published outside the Docker network. Only the
configured default branch triggers anything, and path routing sends a
docs-only commit to *nothing*.

**Production.** mTLS between Gitea and the receiver. A replay window
based on a timestamp header. Rate limiting.

**Residual.** No replay protection: a captured valid request can be
resent. On an isolated network, replaying a deployment of the same
commit is close to harmless — but "close to" is not "is".

---

### 8. Semaphore runner compromise

**Risk.** The runner holds every credential needed to configure every
target. Compromising it is equivalent to compromising all of them.

**PoC mitigation.** Semaphore runs unprivileged in a container with
`no-new-privileges`, a read-only mount of the state directory, and
resource limits. Its Key Store is encrypted at rest with
`SEMAPHORE_ACCESS_KEY_ENCRYPTION`. The database has its own role,
separate from Gitea's.

**Production.** Ephemeral runners, destroyed after each task. Secrets
issued just-in-time from a broker with a short TTL. A separate runner
per trust zone. Egress filtering.

**Residual.** The runner has a long-lived SSH private key and the
Windows administrator password. There is no just-in-time issuance and no
per-task scoping.

---

### 9. WinRM credential theft

**Risk.** A single local administrator password, shared across every
Windows target, held by the automation.

**PoC mitigation.** WinRM is **HTTPS only** (the plaintext listener is
removed), with `AllowUnencrypted=false`, Basic and CredSSP **disabled**,
and Negotiate/NTLM only. The firewall rule is scoped to
`security.management_cidrs`, and the broad built-in WinRM rules are
disabled — otherwise the scoping achieves nothing. The password must
meet the Windows complexity policy, checked before rendering, because
Setup silently rejects a weak one and leaves the account with **no
password at all**.

**Production.** Domain join and **Kerberos** — no shared local
credential. Windows LAPS, rotating per host, with the password in Entra
ID or Active Directory. Just Enough Administration for scoped remote
management. `windows_baseline` reports LAPS readiness (module present,
domain joined) so the gap is visible rather than glossed over.

**Residual.** It is a shared static credential in a workgroup. That is
the honest description.

---

### 10. TLS certificate validation

**Risk.** Ansible connects to Windows with
`ansible_winrm_server_cert_validation: ignore`, so the connection is
encrypted but not authenticated — a machine-in-the-middle on the
provisioning bridge could impersonate the target.

**PoC mitigation.** The certificate is generated **self-signed during
the specialize phase**, with the host name and reserved IP as SANs, so
there is nothing for the runner to trust yet. The setting is
`security.winrm_cert_validation` — a **named, documented, single**
switch, not scattered `--insecure` flags. `wait-for-winrm.sh` prints a
warning every time it runs with validation off and offers
`--validate-tls`. The smoke test follows the same setting. CI **fails**
if any script disables TLS validation without a named control.

**Production.** Issue the WinRM certificate from an internal CA,
distribute the root to the runner's trust store, and set
`winrm_cert_validation: validate`.

**Residual.** The default is `ignore`. It is loud, but it is the
default.

---

### 11. Unsigned boot components

**Risk.** iPXE, wimboot and the Ubuntu kernel are executed before any
operating system, with nothing verifying them.

**PoC mitigation.** iPXE comes from **signed distribution packages** by
default — apt has already verified them. Checksums for everything staged
are recorded in `/srv/forge-ai/tftp/checksums.sha256` and checked by
`verify-checksums.sh`. wimboot is unpinned on a first run and the script
**says so loudly**, printing the digest to pin.

**Production.** UEFI Secure Boot with an enrolled key. A signed shim.
iPXE built with `imgtrust` and signed images. Measured boot with TPM
attestation.

**Residual.** **Secure Boot is off** (`<feature enabled="no"
name="secure-boot"/>`). The distribution's `ipxe.efi` is not signed by a
key in the default OVMF `db`. wimboot is downloaded over HTTPS but is
unpinned unless the operator pins it.

---

### 12. Tampered installation media

**Risk.** A substituted ISO installs a backdoored operating system on
every target.

**PoC mitigation.** The Ubuntu ISO is verified against the **official
`SHA256SUMS`** when no checksum is pinned, and against the pin when
there is one; a mismatch is a hard failure. The Windows ISO's SHA-256 is
always **computed and recorded in the deployment report**, and enforced
when pinned. The VirtIO ISO gets the same treatment — those drivers run
in kernel mode. `--skip-verify` exists but is deliberately loud.

**Production.** Verify the GPG signature on `SHA256SUMS`, not just the
digest. Mirror media internally with provenance. Scan images before use.

**Residual.** The digest is verified but the **signature on
`SHA256SUMS` is not**. An attacker able to substitute both the ISO and
the sums file over HTTPS would defeat this. Windows media has no
publisher checksum to compare against at all — only the operator's own
pin.

---

### 13. Reinstall loops

**Risk.** A host that fails halfway through installation reinstalls
forever. It looks *busy* rather than *broken*, so nobody investigates.
It also consumes the hypervisor indefinitely.

**PoC mitigation.** The state service **increments an attempt counter on
every dispatch** and stops offering the installer past
`pxe.max_install_attempts`, parking the host as `failed`. The libvirt
boot order is flipped to local disk after installation as a second,
independent guard. dnsmasq's `tag:!ipxe` rules make the iPXE chainload
loop structurally impossible. `tests/unit/test_ipxe_selection.py`
exercises all of it.

**Production.** The same, plus alerting on any host that reaches the
attempt limit.

**Residual.** A host that fails *after* reporting `installed` — for
example, `SetupComplete.cmd` never ran — is not reinstalled
automatically. That is deliberate: an automatic rebuild would destroy
the evidence needed to diagnose it.

---

### 14. Accidental destruction

**Risk.** A mistyped command destroys running machines, or the Gitea
repositories and the entire Semaphore audit trail.

**PoC mitigation.** **Three independent confirmations**, because a UI
control is not a security boundary:

1. `make destroy` requires `CONFIRM=DESTROY-POC`;
2. `scripts/destroy.sh` prints exactly what will be removed and what
   will be kept, then requires the token to be **typed**;
3. `destroy-poc.yml` asserts the token again on the Ansible side —
   which is what protects against someone calling the Semaphore API
   directly.

The Semaphore destroy template is numbered `99`, sorts last, and has a
**required** survey variable. Docker volumes are only removed with an
extra explicit `--volumes`. **Deployment reports are never removed.**
Recreating an existing disk fails unless confirmed.

**Production.** Deletion protection on storage. A separate approval role
for destructive workflows. Backups with tested restores.

**Residual.** `FORGE_ASSUME_YES=1` and `--yes` exist for automation and
bypass the interactive prompt. The Ansible-side assertion still holds.

---

## Applied controls

| Control | Where |
|---|---|
| Least privilege | Per-application database roles; scoped Gitea token; `no-new-privileges` on every container |
| Isolated network | libvirt bridge, NAT, no route from the LAN |
| Explicit sudo boundaries | `visudo -cf`-validated drop-in; the scope is stated honestly in the role README |
| No privileged containers | CI **fails** if `privileged: true` appears |
| Read-only mounts | `state` and `webhook` run with `read_only: true` and a tmpfs |
| Pinned image versions | CI **fails** on a `:latest` tag |
| Checksum verification | Every download; `verify-checksums.sh --record` prints what to pin |
| HTTPS everywhere it can be | Gitea, Semaphore, WinRM |
| Webhook HMAC | Verified before parsing |
| Branch protection | Documented in `GITOPS-WORKFLOW.md`; CODEOWNERS enforces review |
| Secret scanning | Gitleaks plus the project's own hygiene tests |
| Dependency scanning | `dependency-review-action` on pull requests |
| Container scanning | Trivy on all three built images |
| Lint | ansible-lint **production profile**, ShellCheck, yamllint, markdownlint |
| No curl-pipe-shell | Enforced by a bats test |
| No silent TLS bypass | Enforced by a bats test and a CI check |
| No shared password | Ubuntu and Windows credentials are separate and independently generated |
| Sanitised logs | `no_log: true` on every task touching a secret; `redact` filter for log lines |
| Destructive safeguards | Three independent confirmations |

---

## Secrets: where each one lives

| Store | Holds | Why there |
|---|---|---|
| **Ansible Vault** | Passwords and tokens for operator-run tasks | The operator has the vault password |
| **Semaphore Key Store** | The same secrets, for Semaphore-run tasks | Encrypted at rest; a runner has no vault password, and giving it one would defeat the point |
| **`compose/.env`** | Control-plane credentials, mode `0600` | Read by Docker at start-up |
| **GitHub Actions secrets** | Only the Gitea sync credential | Nothing else needs to leave GitHub |
| **Semaphore *environment*** | **No secrets** | Semaphore stores it as plain JSON in its database. The template says so in its own comment. |

Every generated file has its mode set **before** content is written
(`install -m 0600 /dev/null`), so there is no window in which a secret
exists in a world-readable file. A bats test asserts that ordering.

---

## Rotating a credential

`create-secrets.sh --force` regenerates, but three values are
**destructive** to regenerate and the script says so before doing it:

| Value | Regenerating it |
|---|---|
| `SEMAPHORE_ACCESS_KEY_ENCRYPTION` | Makes **every key already in the Semaphore Key Store permanently undecryptable** |
| `GITEA_SECRET_KEY` | Invalidates existing sessions and 2FA enrolments |
| The SSH key | Locks you out of already-provisioned Linux targets |

### Rotating without breaking anything

**SSH key:**

```bash
ssh-keygen -t ed25519 -a 100 -N '' -f ~/.ssh/forge-ai-poc-new
# add the NEW public key to config/poc.yml alongside the old one
make configure                      # both keys now authorised
# swap vault_ssh_private_key_path to the new key, verify, then
# remove the old public key from config/poc.yml and re-run
make configure
```

The overlap is the point: never remove the key you are currently using.

**Windows administrator password:**

```bash
ansible-vault edit ansible/inventories/poc/group_vars/all/vault.yml
cd ansible && ansible-playbook -i inventories/poc \
  -m ansible.windows.win_user \
  -a "name=Administrator password={{ vault_windows_admin_password }}" windows
```

**Gitea and Semaphore tokens:** revoke in the UI, create a replacement,
update the vault and `compose/.env`, restart the webhook receiver.

---

## Moving toward production

In the order that buys the most:

1. **Domain-join the Windows target and use Kerberos.** Removes the
   shared local administrator entirely — the single largest residual
   risk here.
2. **Issue real certificates.** An internal CA for WinRM and the
   control-plane proxy, then set `winrm_cert_validation: validate`.
3. **Enable Secure Boot** with signed boot components.
4. **Just-in-time secrets.** A broker issuing short-lived credentials
   per task, instead of long-lived ones in a vault.
5. **Ephemeral runners**, destroyed after each task.
6. **Signed commits and tags**, so a stolen token is not sufficient.
7. **Ship the audit trail** off the host: Semaphore history, auditd,
   Windows event logs.
8. **Network segmentation** with DHCP snooping and 802.1X.

---

## Reporting a vulnerability

Privately, through GitHub Security Advisories:
<https://github.com/danielesalpietro/FORGE-AI/security/advisories/new>

Please do **not** open a public issue.

Note that this is a proof of concept and the residual risks above are
**known and documented**. A report that restates one of them is
welcome — especially if the documentation is wrong or understated — but
what is most useful is a flaw that is *not* already listed, or a case
where a control does not work as this page claims.
