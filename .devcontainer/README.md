# `.devcontainer/`

A container for **working on** this repository.

## What works here

```bash
make validate     # schema, template rendering, Ansible syntax, unit tests
make lint         # yamllint, ansible-lint, ShellCheck, markdownlint
make test         # 204 pytest tests and 29 bats tests
make render       # render every template to /tmp/forge-rendered
```

That is the whole inner loop for changing configuration, templates,
roles, scripts, tests or documentation.

## What does not work here, and why

**Anything that provisions.** A devcontainer has no `/dev/kvm`, so
libvirt cannot start a virtual machine. `make bootstrap`, `make
provision` and everything downstream need a real Ubuntu 24.04 host with
hardware virtualisation enabled.

This is stated up front rather than discovered: `bootstrap/check-prerequisites.sh`
run inside the container reports exactly which prerequisites are absent.

## Why Docker-in-Docker is included

Not for deployment — for `make test-molecule`, which runs the Ubuntu
baseline against a systemd container, and for `docker compose config`
validation. Neither needs KVM.

## The `.venv` volume

`.venv` is mounted as a named volume rather than living in the workspace
bind mount. Python package installation into a bind-mounted directory is
extremely slow on macOS and Windows hosts; a volume avoids that.

## Editor configuration

The devcontainer configures:

- **YAML schema validation** for `config/poc*.yml` against
  `config/schema/poc.schema.json`, so a mistake in the desired state is
  underlined in the editor rather than found by CI;
- **`!vault` as a custom tag**, so an encrypted vault does not show as a
  YAML error;
- **ShellCheck with `-x -P bootstrap:.:scripts`**, matching what CI runs,
  so `source lib/common.sh` resolves;
- **`*.j2` as Jinja** and `*.ipxe` as shell, for syntax highlighting.

## Working without a devcontainer

Nothing depends on it. On any machine with Python 3.12:

```bash
pip install -r ansible/requirements-python.txt
make validate
```
