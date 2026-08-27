# `config/` — the desired state

Everything about the deployed machines lives here. There is exactly one
definition of every address, MAC and resource value.

| File | Tracked | Purpose |
|---|---|---|
| `defaults.yml` | yes | Every tunable, with a comment saying what it does |
| `poc.example.yml` | yes | The operator template — copy it |
| `poc.yml` | **no** | Yours. Git-ignored. |
| `schema/poc.schema.json` | yes | The structural contract |

```bash
cp config/poc.example.yml config/poc.yml
$EDITOR config/poc.yml
make validate
```

## How the two files combine

`defaults.yml` is loaded first; `poc.yml` is **deep-merged** on top.
Only override what you actually need.

Lists are **replaced wholesale**, never concatenated: an operator who
sets `dns_servers` means exactly that list, not the union with the
defaults. Nested mappings merge key by key.

## Validation

Two layers, because neither is sufficient:

### Structural — `schema/poc.schema.json`

Types, enums, patterns, ranges. `additionalProperties: false`
throughout, so a typo in a key name is **rejected** rather than silently
ignored — which is what would otherwise happen, with the default
quietly taking effect.

### Semantic — `scripts/lib/forge_config.py`

The rules a schema cannot express:

| Rejected | Because |
|---|---|
| Duplicate IP or MAC | Two hosts fighting over one reservation |
| Host outside the CIDR | dnsmasq will never answer it |
| Host **inside the DHCP pool** | Eventually collides with a dynamic lease |
| Host equal to the gateway | Collides with the control plane |
| `control_plane.address ≠ gateway` | The boot server binds the bridge address |
| Netmask inconsistent with the CIDR | Silent routing failure |
| Non-locally-administered MAC | Could collide with real hardware |
| Neither `image_name` nor `image_index` | Index 1 is not a safe assumption |
| A live secret in configuration | Belongs in the vault or key store |

Warnings, not errors: an absent Windows ISO (an Ubuntu-only run is
supported), a Windows target under 4 GB, storage paths outside
`artifacts_dir`.

## Where it is used

```text
config/defaults.yml + config/poc.yml
            │
            ├─► forge-inventory.py    Ansible groups, host vars, connections
            ├─► Jinja2 templates      dnsmasq, iPXE, seeds, answer files, XML
            ├─► scripts/lib/          every shell script, via `forge_config`
            └─► tests/                the fixtures render against the real config
```

The inventory **refuses to build** from a configuration that does not
validate, and `ansible.cfg` sets `any_unparsed_is_failed`. An invalid
desired state therefore cannot reach a target: the run stops at
inventory parse time, not three playbooks later.

## Editor support

The devcontainer maps the schema to `config/poc*.yml`, so a mistake is
underlined as you type rather than found by CI. In any editor with the
YAML language server:

```json
"yaml.schemas": {
  "./config/schema/poc.schema.json": ["config/poc*.yml"]
}
```

## Multiple environments

```bash
cp config/poc.example.yml config/lab.yml
make validate FORGE_CONFIG=config/lab.yml
make provision FORGE_CONFIG=config/lab.yml
```

`ansible/inventories/example/README.md` lists what must differ between
two environments on the same host — and notes that `make validate`
catches duplicates *within* one configuration but cannot see the other
one's file.

## Secrets do not go here

`make validate` **rejects** a live-looking secret in configuration. Keys
whose names merely mention a secret — `ssh_password_authentication`,
`destroy_confirmation_token` — are allowlisted, because a check that
cries wolf gets ignored.

`security.ssh_authorized_keys` holds **public** keys and is explicitly
permitted.

Real secrets: `ansible/inventories/poc/group_vars/all/vault.yml`
(encrypted) or the Semaphore Key Store. See `docs/SECURITY.md`.
