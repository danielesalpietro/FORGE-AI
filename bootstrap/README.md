# `bootstrap/`

Getting from a fresh Ubuntu 24.04 host to a working control plane.

```bash
./bootstrap/check-prerequisites.sh    # can this host do it?   (read-only)
./bootstrap/prepare-host.sh           # install what is missing
./bootstrap/create-secrets.sh         # generate every credential
./bootstrap/bootstrap.sh              # bring the control plane up
```

Or `make check`, `make install-host`, `make secrets`, `make bootstrap`.

## `check-prerequisites.sh`

34 read-only checks. Installs nothing, changes nothing.

The memory and disk requirements are **computed from your
`config/poc.yml`**, not hardcoded — reducing a host's `memory_mb` or
removing the Windows target changes what it demands.

Every failure prints the command that fixes it. `--json` for machine
consumption; the bug-report template asks for it, because it answers
most environment questions at once.

## `prepare-host.sh`

Installs 33 packages: virtualisation, provisioning tooling, and the
utilities the rest of the project shells out to.

**Docker is behind an explicit `--install-docker` flag.** Installing a
container runtime rewrites the host's iptables rules and adds a root
daemon; that should be a decision, not a side effect of "prepare the
host".

There is **no curl-pipe-shell**. Docker is installed from the official
APT repository with its GPG key fetched, stored and pinned via
`signed-by` — the method Docker documents, for exactly this reason.

It also disables the packaged `dnsmasq` service, and **says so**, because
FORGE-AI runs its own instance bound only to the provisioning bridge.

`--dry-run` prints what it would do.

## `create-secrets.sh`

Generates, all mode `0600` and all git-ignored:

| File | Contents |
|---|---|
| `compose/.env` | Control-plane credentials |
| `ansible/inventories/poc/group_vars/all/vault.yml` | Encrypted Ansible Vault |
| `.vault-password` | The vault password |
| `~/.ssh/forge-ai-poc{,.pub}` | ed25519 key for the Linux targets |
| `compose/nginx/tls/forge-ai.{crt,key}` | Self-signed proxy certificate |

The **mode is set before the content is written**
(`install -m 0600 /dev/null`), so there is no window in which a secret
exists in a world-readable file. A bats test asserts that ordering.

The public SSH key is recorded in `config/poc.yml` by editing the YAML
textually rather than round-tripping it, so the operator's comments and
ordering survive.

### It never overwrites without `--force`, and says why

Three values are destructive to regenerate, and the script warns and
asks before each:

- `SEMAPHORE_ACCESS_KEY_ENCRYPTION` — makes **every key already in the
  Semaphore Key Store permanently undecryptable**
- `GITEA_SECRET_KEY` — invalidates sessions and 2FA enrolments
- The SSH key — locks you out of already-provisioned Linux targets

`docs/SECURITY.md` has rotation procedures that avoid each.

The Windows password is generated to satisfy the complexity policy
deliberately, not hopefully: Setup silently rejects a weak one and
leaves the account with **no password at all**.

`--show` reports which secrets exist and their modes, printing no
values.

## `bootstrap.sh`

Seven stages, in a dependency order that is enforced rather than
documented:

| Stage | Why it must come here |
|---|---|
| config | Nothing works without a valid desired state |
| secrets | The stack refuses to start without them |
| prereq | Cheaper to fail here than mid-deployment |
| **network** | The bridge must exist **before** Docker can bind `192.168.250.1` |
| control-plane | Gitea and Semaphore must run before they can be configured |
| gitops | A token can only be issued by a running service |
| verify | Confirm every endpoint answers |

Resumable: `--resume-from control-plane`.

The network-before-Compose ordering is the one that bites. Without it,
Docker fails with "cannot assign requested address", which is a much
less useful message than the one this script produces.

## `lib/common.sh`

Shared by every script here and in `scripts/`.

- **Logging** to stderr, so a script's stdout stays usable in a pipeline
- **An error trap** that reports the exit code, the line, the failing
  command and the call stack — "line 47: command not found" alone is
  rarely enough
- **`confirm`** that refuses to assume yes from a non-interactive shell
- **`forge_config`**, delegating to the same Python loader Ansible uses
- **`forge_random_secret`**, which deliberately does *not* pipe `tr`
  into `head -c`: `head` closing the pipe sends SIGPIPE to `tr`, and
  under `pipefail` that is an intermittent exit 141. A bats test covers
  it.
