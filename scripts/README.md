# `scripts/`

Operational tooling. Every script sets `set -Eeuo pipefail`, installs a
call-stack error trap, quotes its expansions, and answers `--help`.

Those properties are **enforced by `tests/bats/test_scripts_interface.bats`**,
not merely intended.

## Media

| Script | Does |
|---|---|
| `prepare-ubuntu-iso.sh` | Download, verify against the official `SHA256SUMS`, extract the kernel and initrd |
| `prepare-windows-iso.sh` | Validate the operator's ISO, record its digest, **list the editions** |
| `build-winpe.sh` | Inject VirtIO drivers into `boot.wim` — on Linux, no DISM, no ADK |
| `download-ipxe-assets.sh` | Stage iPXE and wimboot; record checksums |
| `verify-checksums.sh` | Check every artefact; `--record` prints the YAML to pin |

## Provisioning

| Script | Does |
|---|---|
| `set-boot-state.sh` | Read and change lifecycle state — **asks before queueing a reinstall** |
| `wait-for-ssh.sh` | Wait for an authenticated login, not just an open port |
| `wait-for-winrm.sh` | Probe TCP, then TLS, then WS-Man **separately** |
| `smoke-test.sh` | Verify both targets by reading them; `--junit` for CI |
| `drift-check.sh` | Run detection and summarise it legibly |
| `destroy.sh` | Guarded teardown |

## Development

| Script | Does |
|---|---|
| `validate-config.py` | Schema plus semantic validation; `--format github` for inline PR annotations |
| `render-templates.py` | Render all 21 templates offline and parse each result |
| `lib/forge_config.py` | The shared loader every other tool uses |

## Why the wait-for scripts probe in layers

"WinRM is not working" has three very different causes:

1. nothing listening on 5986;
2. listening, but the TLS handshake fails;
3. TLS fine, but the service is refusing requests while Windows finishes
   its first boot.

A timeout that does not say which is nearly useless. Both scripts test
each layer and, on failure, print the diagnosis **and the command that
addresses it** — including the console recovery for a
`SetupComplete.cmd` that never ran.

## Configuration access

Scripts read the configuration through the same Python loader Ansible
uses, so shell and Ansible cannot disagree about what it says:

```bash
source bootstrap/lib/common.sh
gateway=$(forge_config '.provisioning_network.gateway')
```

`forge_require_valid_config` refuses to proceed on an invalid
configuration.

## Conventions

- **Nothing destructive without confirmation.** `destroy.sh` prints what
  goes and what stays, then requires the token to be typed; the playbook
  checks it again independently.
- **No curl-pipe-shell.** Enforced by a test.
- **No `--insecure` without a named control.** `CURL_TLS_OPTIONS` in the
  smoke test is derived from `security.winrm_cert_validation` and the
  script says which way it resolved.
- **Secrets get their mode before their content** —
  `install -m 0600 /dev/null` then write.
