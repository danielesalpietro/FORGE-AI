# `tests/unit/`

204 tests. No hypervisor, no network, no secrets, about three seconds.

```bash
pytest tests/unit -q
pytest tests/unit/test_ipxe_selection.py -v
```

| File | Tests | Catches |
|---|---|---|
| `test_config_validation.py` | 43 | Duplicate MAC/IP, CIDR membership, DHCP pool overlap, invalid resources, a product key or live secret in configuration |
| `test_template_rendering.py` | 24 | Any template that fails to render or renders invalid YAML; every mandatory autoinstall key; a cleartext password reaching the seed |
| `test_xml_rendering.py` | 28 | `Autounattend.xml` structure pass by pass; a GPT layout that would not boot; the password encoding round-trip; libvirt boot order; VNC bound off-loopback |
| `test_ipxe_selection.py` | 34 | Per-MAC dispatch and **the reinstall-loop guard** |
| `test_filter_plugins.py` | 35 | The filters the templates depend on, including their error cases |
| `test_report_rendering.py` | 16 | Reports rendering from a *partially failed* run; the drift report stating its blind spots |
| `test_secret_hygiene.py` | 24 | Anything sensitive that reached the tracked file list |

## Three things these tests do that are worth copying

### They test the failure, not just the success

A validation rule that never fires is not tested. The suite asserts that
duplicate MACs are **rejected**, that a weak Windows password is
**refused**, that a planted secret is **caught**.

### They exercise the real code

`test_ipxe_selection.py` imports `compose/state-service/app.py` and
calls its `dispatch()`, rather than reimplementing the state machine.
Template tests render through the project's own filters with
`StrictUndefined`. `test_secret_hygiene.py` reads `git ls-files`.

A test against a copy of the logic passes while the real logic is
broken.

### They guard their own coverage

`test_every_template_is_covered_by_a_test` fails when a `.j2` file
exists with no rendering test. It has already caught one — a new
template cannot be added without one.

## Why the secret detector looks the way it does

Detecting a committed credential is a **precision** problem, not a
recall problem: a check that cries wolf gets disabled, and then it
protects nothing.

Its rules were derived by running a naive version over this repository
and classifying every hit. The naive version also missed
`database_password: ...` entirely, because `\bpassword\b` never matches
inside an identifier — and `<something>_password:` is by far the most
common way a credential actually gets committed.

The current version is tested against planted secrets in several
realistic shapes, and both it and `.github/workflows/security.yml` build
their patterns from fragments so that neither scanner trips on its own
source. An exclusion would have been the easy fix, and the exclusion is
what quietly weakens a scanner later.
