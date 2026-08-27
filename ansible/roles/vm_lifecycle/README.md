# `vm_lifecycle`

Creates, boots, re-points and destroys the target virtual machines.

## Boot order is half the loop guard

| Phase | Domain XML | Who decides |
|---|---|---|
| Provisioning | `<boot dev='network'/>` then `hd` | this role |
| Installed | `<boot dev='hd'/>` then `network` | `tasks/set-boot-order.yml` |

The state service decides what a *network* boot receives; this role
decides whether the VM tries the network at all. The redundancy is
deliberate: if the state service were lost entirely, an installed VM
would still come up on its own disk rather than reinstalling.

### Documented failure modes

- **A redefinition only takes effect on the next boot.** A VM that is
  mid-reboot when `set-boot-order.yml` runs uses the old order once. The
  state service covers that case — it answers "boot local" for an
  installed host regardless.
- **UEFI NVRAM keeps its own boot order**, independent of libvirt. The
  Ubuntu autoinstall runs `efibootmgr` in a late-command; Windows Setup
  writes its own entry. If a VM still network-boots after this role has
  run, look at
  `/var/lib/libvirt/qemu/nvram/<domain>_VARS.fd` — and note that
  `destroy.yml` passes `--nvram` for exactly this reason.

## Destroying a disk is never implicit

`vm_lifecycle_recreate_disk=true` on a host whose qcow2 already exists
**fails** unless `confirm_destroy` matches
`safety.destroy_confirmation_token` or `forge_force=true` is set. The
message lists the disks and their sizes.

## Redefinition on drift

If `config/poc.yml` changes vCPU, memory or boot order, the re-rendered
XML differs and the role redefines the existing domain. Without that
step the desired state in Git and the running machine quietly diverge —
which is exactly the drift this platform is supposed to catch.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `vm_lifecycle_state` | `running` | `present` / `running` / `stopped` / `absent` |
| `vm_lifecycle_recreate_disk` | `false` | Destructive; guarded |
| `vm_lifecycle_redefine` | `false` | Force redefinition from the rendered XML |
| `forge_boot_target` | `network` | `network` or `hd` |
| `vm_lifecycle_purge_nvram` | `true` | Remove UEFI NVRAM on destroy |

## Tags

`provisioning`, `validation`, `drift`, `destroy`
