# `inventories/example/` — a second environment, by copy

This directory shows how to run FORGE-AI against more than one
environment without editing anything under `inventories/poc/`.

## What an environment is

An environment is a pair:

1. a configuration overlay (`config/<name>.yml`), and
2. an inventory directory that points the loader at it.

`inventories/poc/` is the shipped environment. Everything it contains is
either derived from `config/poc.yml` (the dynamic inventory) or is a
property of the run rather than of the desired state (`group_vars/`).

## Creating one

```bash
# 1. the desired state
cp config/poc.example.yml config/lab.yml
$EDITOR config/lab.yml            # change the network, the MACs, the hosts

# 2. the inventory
cp -r ansible/inventories/example ansible/inventories/lab
```

`inventories/example/forge-inventory.py` is a symlink to the shipped
loader; it honours the `FORGE_CONFIG` environment variable, so the
environment is selected at run time:

```bash
cd ansible
FORGE_CONFIG=../config/lab.yml ansible-inventory -i inventories/lab --list
FORGE_CONFIG=../config/lab.yml ansible-playbook -i inventories/lab playbooks/site.yml
```

`make` targets accept the same variable:

```bash
make validate FORGE_CONFIG=config/lab.yml
make provision FORGE_CONFIG=config/lab.yml
```

## What must differ between environments

Two environments on the same KVM host will collide unless all of these
are distinct:

| Setting | Why |
|---|---|
| `provisioning_network.name` | libvirt network names are unique per host |
| `provisioning_network.bridge` | one bridge device per network |
| `provisioning_network.cidr` | overlapping subnets break routing |
| `hosts[].mac_address` | the dnsmasq reservation and the iPXE dispatch both key on MAC |
| `hosts[].name` | libvirt domain names are unique per host |
| `storage.artifacts_dir` | each environment owns its boot artefacts |
| `control_plane.boot_http_port` | one listener per address:port |

`make validate` catches duplicates *within* one configuration. It cannot
see the other environment's file, so cross-environment collisions are
caught at apply time by libvirt — which is late. The
`prerequisite_validation` role therefore also checks the live host for
an existing network, bridge, domain and listener before creating
anything.

## `group_vars/` here

Left empty on purpose. A new environment inherits the shipped
`group_vars/` semantics by copying `inventories/poc/group_vars/` into
place and editing only what differs — most often just the vault path.
