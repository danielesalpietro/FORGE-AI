# `tests/fixtures/`

## `render_context.py`

Builds the variable context a template receives **from Ansible** — the
merged configuration, the run-scoped variables the playbooks set, and
stand-ins for the values a real run would decrypt from the vault.

Rendering a template offline only proves something if the context
matches what Ansible actually provides. This module is what makes that
true, and it is shared with `scripts/render-templates.py` so that CI and
the operator tool cannot disagree about what "what a template gets"
means.

```python
from render_context import build_context

context = build_context(config, host=host)
output = jinja_env.get_template("windows/Autounattend.xml.j2").render(**context)
```

## The fixture secrets are deliberately obvious

```python
"vault_ubuntu_bootstrap_password": "FIXTURE-NOT-A-REAL-PASSWORD"
"vault_windows_admin_password":    "FixturePassword123!Aa1"
```

Two reasons:

1. **A leak is recognisable at a glance.** CI greps the rendered
   artefacts for `FIXTURE-NOT-A-REAL-PASSWORD` and fails if it finds it
   — which is only a meaningful check because the value is
   unmistakable.
2. **They exercise the real code paths.** The Windows password is built
   to satisfy the complexity policy the role asserts, and the Ubuntu
   hash is yescrypt-shaped so the format assertion actually runs.

Nothing rendered from these fixtures should ever be deployed.
`render-templates.py --out` says so on every run.

## Keeping it honest

`build_context` mirrors what the dynamic inventory publishes, including
the two keys Ansible reserves as play keywords: `hosts` becomes
`forge_hosts`, and `environment` is `deployment` in the configuration
itself.

If a role starts providing a new variable to a template, add it here —
otherwise the template renders in CI under `StrictUndefined` and fails
on the host, which is the wrong way round.
