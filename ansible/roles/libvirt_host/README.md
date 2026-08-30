# `libvirt_host`

Prepares the KVM host: packages, `libvirtd`, group membership, the
storage pool and the `/srv/forge-ai` directory tree that every other
role writes into.

## Notable details

- **`{{ storage.state_dir }}` is owned by UID/GID 10001.** The state
  service container runs unprivileged as that fixed UID
  (`compose/state-service/Dockerfile`) and bind-mounts this directory
  read-write. Changing the UID in the Dockerfile means changing it here
  too.
- **Group membership needs a new login.** Adding the operator to
  `libvirt` and `kvm` does not affect the session that ran Ansible. The
  role says so explicitly rather than letting the next `virsh` call fail
  confusingly.
- **The storage pool `define` is tolerant of an existing pool** but not
  of other failures, so a re-run is a no-op and a genuine error still
  stops the play.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `libvirt_host_install_packages` | `true` | Set false when packages are managed elsewhere |
| `libvirt_host_users` | invoking user | Added to `libvirt` and `kvm` |
| `libvirt_host_manage_storage_pool` | `true` | Define and start `storage.libvirt_pool_name` |

## Outputs

`forge_component_versions` — a cacheable fact mapping component name to
version string, quoted verbatim in the deployment report.

## Tags

`bootstrap`, `provisioning`, `validation`
