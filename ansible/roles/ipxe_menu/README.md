# `ipxe_menu`

Renders the iPXE scripts and the host registry, then proves the dispatch
path actually answers.

## What it produces

| Artefact | Path | Consumed by |
|---|---|---|
| Entry point | `http/boot/boot.ipxe` | Every iPXE client (`dhcp-boot=tag:ipxe,...`) |
| Fallback menu | `http/boot/menu.ipxe` | Unknown MACs, and the operator |
| Per-host installer | `http/boot/host-<mac>-install.ipxe` | The state service, by `chain` |
| Host registry | `state/registry.json` | The state service, to map MAC → host |

## Who decides what boots

This role writes the *options*. The **state service decides**, per boot,
which one a client receives — see `compose/state-service/app.py`. That
separation is what makes the reinstall-loop guard possible: a static
file server cannot count attempts.

`registry.json` is written mode `0640`, owned by UID/GID 10001, because
the state service container runs as that unprivileged user. If it is
unreadable the service answers "unknown MAC" for every host and every
machine drops to the fallback menu.

## Resetting state

```bash
# Re-run the stack without touching working machines (default)
ansible-playbook playbooks/deploy-pxe-stack.yml

# Queue a reinstall for hosts in new/installing/failed
ansible-playbook playbooks/deploy-pxe-stack.yml -e ipxe_reset_state=true

# Rebuild a host that is already 'ready' -- destroys its installed OS
ansible-playbook playbooks/deploy-pxe-stack.yml \
  -e ipxe_reset_state=true -e ipxe_reset_force=true
```

The default `ipxe_reset_states` deliberately excludes `installed`,
`configuring` and `ready`. A routine re-run of the PXE stack must never
queue a reinstall of a working machine; that needs `ipxe_reset_force`.

## Verification

The role ends by fetching `/state/<mac>.ipxe` for every host and
asserting the response starts with `#!ipxe`. A failure here means the
problem is in the control plane, not in the guest — which is worth
knowing before spending twenty minutes watching a VM fail to boot.

## Tags

`provisioning`, `network`, `linux`, `windows`, `validation`
