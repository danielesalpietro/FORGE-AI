# `tests/`

Four layers, each answering a different question, each runnable
independently.

| Layer | Command | Needs | Runtime |
|---|---|---|---|
| **Unit** | `pytest tests/unit` | nothing | ~3 s |
| **Shell** | `bats tests/bats` | `bats` | ~10 s |
| **Molecule** | `molecule test -s ubuntu_baseline` | Docker | ~3 min |
| **Integration** | `pytest tests/integration -m integration` | a live control plane | ~5 s |
| **Smoke** | `./scripts/smoke-test.sh` | provisioned VMs | ~2 min |

`make test` runs the first two. `make validate` runs the unit tests plus
schema validation and Ansible syntax checks — that is what CI runs on
every pull request.

## What each layer catches

### `tests/unit/` — 204 tests, no hypervisor, no network

| File | Catches |
|---|---|
| `test_config_validation.py` | Duplicate MAC/IP, hosts outside the CIDR or inside the DHCP pool, a gateway that disagrees with the control-plane address, invalid resources, unsupported profiles, a product key or a live secret in configuration |
| `test_template_rendering.py` | Any template that fails to render, or renders invalid YAML; every mandatory autoinstall key; a cleartext password reaching the seed |
| `test_xml_rendering.py` | `Autounattend.xml` that is not well-formed or is missing a configuration pass; a GPT layout that would not boot; a password encoding that leaves the account with *no* password; libvirt boot order; VNC bound off-loopback |
| `test_ipxe_selection.py` | Per-MAC dispatch, and **the reinstall-loop guard** — that the installer stops being offered at the attempt limit and that a parked host stays parked |
| `test_filter_plugins.py` | The filters the templates depend on, including the Windows password encoding round-trip |
| `test_report_rendering.py` | Reports that render from a *partially failed* run, and that the drift report states its own blind spots |
| `test_secret_hygiene.py` | Anything sensitive that reached the tracked file list |

Rendering uses `StrictUndefined`, so a variable a template needs but no
role provides is a test failure rather than a silently empty string.

**The coverage guard.** `test_every_template_is_covered_by_a_test` fails
when a `.j2` file exists with no rendering test. A new template cannot
be added without one.

**The secret detector is tested against planted secrets**, not only
against a clean tree — a hygiene check that always passes protects
nothing. Its rules were derived by running a naive version over this
repository and classifying every hit; precision matters, because a check
that cries wolf gets disabled.

### `tests/bats/` — 29 tests

`test_common_lib.bats` covers `bootstrap/lib/common.sh`: secret
generation under `set -o pipefail` (the SIGPIPE bug that a naive
`tr | head -c` reintroduces), file modes set *before* content is
written, and `confirm` refusing to assume yes from a non-interactive
shell.

`test_scripts_interface.bats` enforces the contract every script honours:
a bash shebang, `set -Eeuo pipefail`, the error trap, `--help`, rejection
of unknown options, no curl-pipe-shell, and no `--insecure` without a
named control.

### `tests/molecule/ubuntu_baseline/`

Runs the Ubuntu baseline against a systemd container. Its `idempotence`
step fails the run if a second apply reports **any** change — the exact
property the drift report depends on.

The scenario is explicit about what a container **cannot** verify: ufw
(a container shares the host netfilter tables), `qemu-guest-agent` (no
virtio-serial channel) and reboot handling. A green Molecule run is not
the same as a working host; treating it as one is how a PoC misleads.
Those are covered by the smoke test against a real VM.

### `tests/integration/`

Probes a live control plane once and skips the whole module if it is not
there, so the same `pytest` invocation works in CI and on a KVM host.

### `scripts/smoke-test.sh`

The end-to-end check, against real machines. Verifies both targets by
reading them rather than trusting a playbook's exit code, and runs the
configuration a second time in check mode to report whether anything
would still change. `--junit results.xml` for CI.

## Fixtures

`tests/fixtures/render_context.py` builds the variable context a
template receives from Ansible — the merged configuration, the run-scoped
variables, and stand-ins for the vault values. It is shared with
`scripts/render-templates.py`, so CI and the operator tool agree on what
"what a template gets" means.

Fixture secrets are obviously fake (`FIXTURE-NOT-A-REAL-PASSWORD`) so a
leak into a rendered artefact is recognisable at a glance.
