# `tests/molecule/`

Role testing against real (containerised) systems.

```bash
cd tests/molecule/ubuntu_baseline && molecule test
# or
make test-molecule
```

## Scenarios

| Scenario | Role | Verifies |
|---|---|---|
| `ubuntu_baseline/` | `ubuntu_baseline` | The role runs, is **idempotent**, and produces the state it claims |

## The step that matters

Molecule's `idempotence` step runs the role a second time and **fails
the run if anything reports changed**.

That is not a stylistic check. `configure-targets.yml` is exactly what
`detect-drift.yml` runs under `--check`, so a task that reports changed
on every run makes the drift report cry wolf permanently — and a drift
report nobody trusts is worse than none.

## What a container cannot verify

Stated in the scenario's own header, because a green Molecule run is not
the same as a working host and treating it as one is how a proof of
concept misleads:

| Not verified | Why |
|---|---|
| **ufw** | A container shares the host netfilter tables. Enabling a default-deny policy inside one is either a no-op or a very bad idea. |
| **qemu-guest-agent** | No virtio-serial channel. `prepare.yml` installs a stub unit so the role's service tasks run unchanged, rather than forcing the role to grow a container-only branch. |
| **Reboot handling** | A container has no kernel of its own. |

Those are covered by `scripts/smoke-test.sh` against a real VM.

## Adding a scenario

```bash
mkdir tests/molecule/<role_name>
```

Four files, following `ubuntu_baseline/`:

| File | Purpose |
|---|---|
| `molecule.yml` | Platform, provisioner variables, test sequence |
| `prepare.yml` | What a real host would already have from its installation |
| `converge.yml` | Apply the role |
| `verify.yml` | **Read the system back** — do not trust converge's exit code |

Two things worth copying from the existing scenario:

- `group_vars` in `molecule.yml` restates the minimum the role expects
  from the dynamic inventory, keeping the scenario self-contained.
- The header documents what the scenario **cannot** check. Be explicit
  about it; that is the difference between a test and a reassurance.

## Windows

There is no Molecule scenario for `windows_baseline`. Windows does not
containerise in a way that would tell us anything useful, and the role's
behaviour depends on Windows Setup having actually run.

It is covered instead by the read-only compliance probes in
`validate.yml`, and by `scripts/smoke-test.sh` against a real machine.
`docs/LIMITATIONS.md` records that the Windows path has less automated
coverage than the Ubuntu one.
