## What does this change?

<!-- One or two sentences. What is different after this merges? -->

## Why?

<!-- The problem, not the solution. If it fixes an issue, link it. -->

Closes #

## Type of change

- [ ] `feat` — new capability
- [ ] `fix` — corrects a defect
- [ ] `docs` — documentation only
- [ ] `refactor` — no behaviour change
- [ ] `test` — tests only
- [ ] `chore` — tooling, dependencies, CI
- [ ] `BREAKING CHANGE` — requires operator action (describe it below)

## Blast radius

Which parts of the lifecycle does this touch?

- [ ] Configuration model or schema
- [ ] Boot chain (dnsmasq, iPXE, the state service)
- [ ] Installation media or answer files
- [ ] VM lifecycle
- [ ] Target baselines (Ubuntu or Windows)
- [ ] Control plane (Gitea, Semaphore, Compose)
- [ ] Drift detection or reconciliation
- [ ] Documentation or tests only

## How was it verified?

- [ ] `make validate` passes
- [ ] `make lint` passes
- [ ] New or changed behaviour has a test
- [ ] Deployed end to end on a KVM host
- [ ] Ran twice — the second run reported no unexpected changes
- [ ] Not verifiable without hardware; explained below

<!--
Say what you actually ran, and what you could not. "make validate passes
and I deployed the Ubuntu target; the Windows path is untested because I
have no media" is far more useful than an unqualified tick.
-->

## Security

- [ ] No secret, key, token, ISO or WIM is added to the repository
- [ ] Any new download has a pinned checksum, or explains why not
- [ ] Any new external call has TLS validation, or a named control that
      disables it and a note in `docs/SECURITY.md`
- [ ] Any new destructive path is guarded by an explicit confirmation
- [ ] Nothing new runs privileged, or it is documented as unavoidable

## Operator impact

<!--
Does an operator have to do anything on upgrade? Change config/poc.yml,
regenerate a secret, re-run bootstrap, rebuild a VM? Say so plainly, and
add it to CHANGELOG.md under BREAKING CHANGE if it is required.
-->

- [ ] No operator action required
- [ ] Operator action required, described above and in `CHANGELOG.md`

## Documentation

- [ ] `docs/` updated, or no documentation change is needed
- [ ] `docs/COMPATIBILITY.md` updated if a version was tested or bumped
- [ ] `docs/LIMITATIONS.md` updated if a limitation was added or removed
