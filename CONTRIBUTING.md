# Contributing

## The short version

```bash
git checkout -b feat/your-change
# ... make the change ...
make validate          # must pass
make lint              # must pass
git commit -m "feat(scope): what changed"
gh pr create
```

Then, in the pull request, **say what you actually verified**. "`make
validate` passes and I deployed the Ubuntu target; the Windows path is
untested because I have no media" is far more useful than an unqualified
tick.

---

## Setting up

### With a devcontainer

Open the repository in VS Code and reopen in the container. Everything
needed to lint, test and render is installed.

It **cannot deploy** — there is no `/dev/kvm` in a devcontainer. That is
stated up front rather than discovered.

### Without one

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r ansible/requirements-python.txt

sudo apt-get install -y shellcheck bats jq libxml2-utils wimtools p7zip-full
npm install -g markdownlint-cli@0.42.0

make validate
```

### To actually deploy

An Ubuntu 24.04 host with hardware virtualisation, 16 GB of RAM and
150 GB of disk. `docs/QUICKSTART.md`.

---

## What runs before your change is accepted

```bash
make validate    # schema, template rendering, Ansible syntax, 233 tests
make lint        # yamllint, ansible-lint (production profile), ShellCheck
```

`make validate` is exactly what CI runs. If it passes locally, CI will
pass — the same commands, the same versions.

| Check | Requirement |
|---|---|
| Configuration schema | Every change to `config/` validates |
| Template rendering | All 21 templates render under `StrictUndefined` and parse |
| Ansible syntax | All 15 playbooks |
| `ansible-lint` | **Production profile**, zero findings |
| ShellCheck | Zero findings across all 17 scripts |
| yamllint | Zero errors |
| Unit tests | 204, all passing |
| Shell tests | 29, all passing |
| Secret hygiene | Nothing sensitive in the tracked file list |

---

## Standards

### Shell

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
export FORGE_SCRIPT_NAME="your-script.sh"
# shellcheck source=bootstrap/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../bootstrap" && pwd)/lib/common.sh"
forge_enable_traps
```

Enforced by `tests/bats/test_scripts_interface.bats`:

- `set -Eeuo pipefail` and the error trap
- `--help` that exits 0, and rejection of unknown options
- Every variable expansion quoted
- **No curl-pipe-shell** — downloading and executing in one step means
  nothing can be inspected between the two
- **No `--insecure` without a named control**, so the choice is visible
  in the code and reportable to the operator

### Ansible

- **Fully qualified module names**, always. A short name resolves
  differently depending on which collections happen to be installed, and
  CI rejects them.
- **Tags on every task**: `bootstrap`, `provisioning`, `linux`,
  `windows`, `security`, `validation`, `drift`, `destroy`.
- **Handlers for service restarts**, and `meta: flush_handlers` before
  any verification that depends on the restart having happened.
- **`validate:` on anything that could lock you out.** `sshd -t -f %s`,
  `visudo -cf %s`, `xmllint --noout %s`, `dnsmasq --test`. A rejected
  sshd config on a headless VM reachable only over SSH is unrecoverable.
- **`no_log: true`** on every task touching a secret.
- **Every role gets a `README.md`** explaining what it does *and why the
  non-obvious parts are that way*.

#### Write for check mode

The baseline roles are what `detect-drift.yml` runs with `--check`. A
task that is "idempotent in practice" but reports `changed` on every run
makes the drift report cry wolf permanently — and a drift report nobody
trusts is worse than none.

If a module has no check-mode support (`win_shell`, `win_command`), mark
it `check_mode: false` **and add a read-only compliance probe** in
`group_vars/{linux,windows}/main.yml`. That is how the project stays
honest about its coverage.

### Templates

- `StrictUndefined` — a missing variable is an error, not an empty
  string
- Comments in the rendered output where the format allows, saying which
  template produced it
- **Every new template needs a rendering test.**
  `test_every_template_is_covered_by_a_test` fails otherwise, by design.

### Python

- Standard library only for `compose/state-service` and
  `compose/webhook` — their dependency surface should stay at the base
  image
- Type hints on function signatures
- Docstrings that say *why*, not *what*

---

## Comments

Explain **why**, not what. The code says what.

Worth a comment:

- A non-obvious constraint — *"WinPE has no PowerShell, so this is
  batch"*
- A trap someone will otherwise fall into — *"the trailing slash is
  mandatory: cloud-init appends filenames verbatim"*
- A deliberate choice that looks like an omission — *"not a handler:
  this must be said at the moment it happens, not deferred"*
- A limitation stated plainly — *"this is obfuscation, not encryption"*

Not worth a comment: `# increment the counter` above `counter += 1`.

---

## Commits

[Conventional Commits](https://www.conventionalcommits.org/):

```text
feat(pxe): add UEFI HTTP Boot support for client-arch 16

Firmware with UEFI 2.5+ can fetch the boot binary over HTTP instead of
TFTP, which is markedly faster and avoids TFTP's lock-step ACK.

Requires dhcp-option-force=tag:efihttp,60,HTTPClient -- the firmware
will not accept a URL as a boot filename without the vendor class.
```

| Type | Version impact |
|---|---|
| `feat` | minor |
| `fix` | patch |
| `docs`, `test`, `refactor`, `chore`, `ci`, `style`, `perf` | none |
| `BREAKING CHANGE:` in the footer | **major** |

Scopes: `config`, `ansible`, `pxe`, `windows`, `ubuntu`, `compose`,
`security`, `docs`, `ci`, `tests`.

The body should say **why**, and name any consequence an operator needs
to know about.

---

## Tests

| Change | Needs |
|---|---|
| Configuration schema | A test in `test_config_validation.py`, including the **rejection** case |
| A template | A rendering test, and a parse test for its format |
| A filter | A test in `test_filter_plugins.py`, including its error cases |
| A shell helper | A bats test |
| A role | Ideally a Molecule scenario |
| Boot dispatch logic | A test in `test_ipxe_selection.py` |

### Test the failure, not just the success

A validation rule that never fires is not tested. The suite asserts that
duplicate MACs are **rejected**, that a weak password is **refused**,
that a planted secret is **caught**. CI includes a negative test for
exactly this reason: if duplicate detection ever stops working, the
build fails rather than passing everything through.

---

## Documentation

If a change affects an operator, update the documentation in the same
pull request.

| Change | Update |
|---|---|
| Behaviour | The relevant `docs/*.md` |
| A new failure mode | `docs/TROUBLESHOOTING.md` |
| A security property | `docs/SECURITY.md` |
| A new or removed limitation | `docs/LIMITATIONS.md` |
| A tested version | `docs/COMPATIBILITY.md` |
| Anything an operator must do on upgrade | `CHANGELOG.md`, under BREAKING CHANGE |

### Do not overstate

If a claim is stronger than the code supports, weaken the claim.
`docs/LIMITATIONS.md` has a table of exactly where language was
deliberately softened — "CIS-inspired" rather than "CIS-compliant",
"drift detection with two sources, both with stated limits" rather than
"complete drift detection".

A repository that overstates its coverage is worse than one that is
explicit about the gaps. If you find a place where this repository does
overstate, that is a bug worth reporting.

---

## Adding to the desired state

Changing `config/defaults.yml` or the schema:

1. Add the key to `config/defaults.yml` with a comment saying what it
   does
2. Add it to `config/schema/poc.schema.json` with type, constraints and
   a `description`
3. Add a semantic rule to `scripts/lib/forge_config.py` if the schema
   cannot express what is actually valid
4. Add a test for the **rejection** case
5. Document it wherever an operator would look for it

`additionalProperties: false` throughout means a typo in a key name is
rejected rather than silently ignored. Keep it that way.

---

## Security-relevant changes

CODEOWNERS requires review on: the boot chain
(`ansible/templates/ipxe/`, `dnsmasq/`, `compose/state-service/`), the
answer files (`ansible/templates/windows/`, `ubuntu/`),
`bootstrap/create-secrets.sh`, `docs/SECURITY.md` and `.github/`.

If your change touches security posture, say so plainly in the pull
request and update the threat model. Adding a mitigation is good;
**adding a mitigation and removing the residual-risk note that no longer
applies** is better.

---

## Pull requests

The template asks for:

- What changed, and why
- **Blast radius** — which parts of the lifecycle this touches
- **How it was verified** — including what you could *not* verify
- **Security** — no secrets, pinned checksums, TLS, destructive guards
- **Operator impact** — does anyone have to do anything on upgrade?

Reviewers look for: does it fail early with a useful message; is it
idempotent and check-mode-safe; is the failure mode documented; does it
overstate anything.

---

## Releasing

Maintainers only.

```bash
$EDITOR CHANGELOG.md      # FIRST -- release.yml fails without an entry
git commit -am "chore(release): prepare 1.2.0"
git push origin main
git tag -a v1.2.0 -m "FORGE-AI 1.2.0"
git push origin v1.2.0
```

The release workflow verifies the tag is semantic and on `main`, that
the changelog documents it, re-runs the full validation suite, builds
the archive from an **allowlist**, and then re-inspects the archive for
media and secrets before publishing.

Dry run: **Actions → release → Run workflow**.

---

## Code of conduct

Be straightforward and be kind. Assume competence. Say what you mean
about the code, and say it about the code rather than the person.

Disagreement about a technical decision is welcome — this project has
several, and they are documented with their reasoning precisely so they
can be argued with.
