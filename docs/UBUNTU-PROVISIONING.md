# Ubuntu provisioning

From bare disk to a machine Ansible can configure.

---

## The path

```text
iPXE
 └─ casper/vmlinuz + casper/initrd          extracted from the ISO
     └─ url=http://.../ubuntu-24.04.3.iso   casper fetches the squashfs
         └─ ds=nocloud;s=http://.../poc-ubuntu-01/
             └─ Subiquity, fully unattended
                 ├─ late-commands: harden sshd, POST state=installed
                 └─ reboot → local disk → SSH
```

---

## There is no netboot image for 24.04 Server

This one fact shapes everything else.

Ubuntu stopped shipping `netboot.tar.gz` for Server. The supported
network installation path is:

1. boot `casper/vmlinuz` and `casper/initrd`, **extracted from the
   live-server ISO**;
2. pass `url=<http url to the ISO>` so casper fetches the ISO itself and
   finds the squashfs inside it.

So `ubuntu_media` extracts exactly two files and then publishes the whole
3 GB ISO over HTTP. That is not a workaround — it is the mechanism.

`7z` reads the ISO 9660 image directly rather than loop-mounting it: no
root needed, and nothing left behind if a play is interrupted.

---

## The kernel command line

From `ansible/templates/ipxe/host-ubuntu-install.ipxe.j2`:

```text
kernel  http://192.168.250.1:8080/ubuntu/casper/vmlinuz
initrd  http://192.168.250.1:8080/ubuntu/casper/initrd

imgargs vmlinuz \
  initrd=initrd \
  ip=dhcp \
  url=http://192.168.250.1:8080/iso/ubuntu-24.04.3-live-server-amd64.iso \
  autoinstall \
  ds=nocloud;s=http://192.168.250.1:8080/ubuntu/poc-ubuntu-01/ \
  cloud-config-url=/dev/null \
  net.ifnames=0 \
  fsck.mode=skip \
  console=tty0 console=ttyS0,115200n8 \
  ---
```

| Parameter | Why it is there |
|---|---|
| `ip=dhcp` | casper needs an address before it can fetch anything |
| `url=` | Where casper gets the ISO, and therefore the squashfs |
| `autoinstall` | Tells Subiquity to run unattended |
| `ds=nocloud;s=` | The seed directory. **Trailing slash mandatory.** |
| `cloud-config-url=/dev/null` | Stops cloud-init finding a datasource elsewhere |
| `net.ifnames=0` | Predictable `eth0`, so the netplan match is stable |
| `fsck.mode=skip` | The disk is about to be wiped |
| `console=ttyS0` | Makes `virsh console` show the installer |
| `---` | Everything after this is passed to the installed system |

### The trailing slash

cloud-init appends the filenames to the `s=` value **verbatim**. Without
the trailing slash it requests `…/poc-ubuntu-01user-data`, gets a 404,
finds no datasource, and drops to an interactive prompt.

On a headless VM that is indistinguishable from a hang. It is the most
common Ubuntu PXE failure there is, and
`tests/unit/test_ipxe_selection.py` asserts the slash is present.

### `nocloud` rather than `nocloud-net`

cloud-init 24.x deprecated `nocloud-net`. `ds=nocloud;s=http://…` with
an HTTP seed is the current spelling and does the same thing. For
cloud-init older than 23.10, `nocloud-net` is still needed.

---

## The seed

Three files per host, rendered by `ubuntu_autoinstall`:

| File | Purpose |
|---|---|
| `user-data` | The autoinstall answer file |
| `meta-data` | `instance-id` and `local-hostname` |
| `vendor-data` | Empty — it exists because a missing one logs a 404, which is noise during a demonstration |

`instance-id` includes the deployment ID. A changed `instance-id` is
what tells cloud-init this is a genuinely new machine rather than a
reboot of a known one; without that, per-instance modules are skipped.

### What the answer file configures

```yaml
autoinstall:
  version: 1
  interactive-sections: []      # fail loudly rather than prompt

  locale, keyboard, timezone    # from config/poc.yml

  network:                      # matched by MAC, renamed to eth0
    ethernets:
      primary:
        match: {macaddress: "52:54:00:25:00:21"}
        set-name: eth0
        dhcp4: true

  storage:                      # GPT: 1 GB ESP, 2 GB /boot, LVM remainder
    config: [...]

  identity:
    hostname, username
    password: "$y$..."          # a HASH, never cleartext

  ssh:
    install-server: true
    allow-pw: false             # key authentication only
    authorized-keys: [...]

  packages: [...]               # from baseline.ubuntu.packages
  late-commands: [...]
  error-commands: [...]
```

### The storage layout

GPT with three partitions, then LVM:

| Partition | Size | Purpose |
|---|---|---|
| ESP | 1 GB | UEFI boot, FAT32 |
| `/boot` | 2 GB | Separate, so the root LV can be encrypted later without moving the kernel |
| LVM PV | remainder | |

The root LV takes **70%** of the volume group, deliberately leaving
headroom so `lvextend` can be demonstrated on a live system.

`match: size: largest` avoids hard-coding `/dev/vda`, which changes with
the disk bus.

### Secrets in the seed

The seed carries a **crypt(3) hash** — yescrypt or SHA-512 — never a
cleartext password. The role asserts the format before rendering,
because a cleartext value would be served over HTTP *and* written into
`/var/log/installer` on the target.

It also **refuses to render** when `security.ssh_authorized_keys` is
empty: the installed host disables SSH password authentication, so
without a key Ansible could never reach it. Failing there costs seconds;
discovering it after a 15-minute install does not.

The seed is **purged** once the host reports `installed`, leaving a
`PURGED.txt` that explains how to re-render it.

---

## late-commands

These run inside `/target` at the end of the installation.

```yaml
late-commands:
  # 1. Harden sshd BEFORE the first boot, not after
  - |
    cat > /target/etc/ssh/sshd_config.d/10-forge-ai.conf <<'SSHD'
    PermitRootLogin no
    PasswordAuthentication no
    ...
    SSHD

  # 2. Preserve the installer logs on the installed system
  - cp -a /var/log/installer /target/var/log/forge-ai-installer || true

  # 3. Tell the state service the installation finished
  - curl -X POST -d '{"state":"installed",...}' .../api/state/52-54-00-25-00-21

  # 4. Point the guest's own UEFI NVRAM at the local disk
  - curtin in-target -- efibootmgr -o ...
```

**Step 3 is what stops a reinstall loop.** The reboot that follows must
not land back in the installer, and this call is what flips the state.

**Step 4 is belt and braces.** UEFI NVRAM keeps its own boot order,
independently of libvirt, and survives a domain redefinition.

`error-commands` reports `failed` and uploads `/var/log/installer` to
the boot server, so a failed install is diagnosable without console
access.

---

## The baseline

Applied over SSH afterwards by `ubuntu_baseline`:

| Area | What |
|---|---|
| Identity | Hostname verified against the inventory, `/etc/hosts` |
| Packages | `baseline.ubuntu.packages` plus per-host extras |
| Users | Automation account, authorised keys (`exclusive: true`), scoped sudo, root locked |
| SSH | Hardening drop-in, banner, verified against `sshd -T` |
| Firewall | ufw default-deny, SSH scoped to `management_cidrs` |
| Time | chrony, timesyncd stopped, sync verified |
| Audit | auditd rules for identity, sudoers, sshd, privilege escalation |
| CIS-inspired | Kernel hardening, module blacklist, file permissions |
| Health | `/usr/local/bin/forge-health` |

### `exclusive: true` on authorised keys

A key added by hand on the target is **drift**, and is removed. That is
the point of a GitOps desired state — but it is worth knowing before it
surprises you.

### Ordering that matters

- **The ufw SSH allow rule is created before the default-deny policy.**
  The other order locks Ansible out of the host mid-play.
- **Handlers are flushed early** in `ssh.yml` and `time.yml`, so the
  verification that follows tests the *new* configuration.
- **`validate: sshd -t -f %s` and `visudo -cf %s`.** A rejected sshd
  config or a malformed sudoers file, on a headless VM reachable only
  over SSH, is unrecoverable without console access.

### The CIS-inspired controls are not a benchmark

`cis-demo.yml` applies settings informed by the CIS Ubuntu Benchmark. It
is **not** a benchmark run and must not be reported as CIS conformance —
a real assessment covers several hundred controls with evidence
collection. The role says so in its own output.

Two deliberate omissions:

- `-e 2` (immutable audit rules) would force a reboot for every drift
  reconciliation.
- `Unattended-Upgrade::Automatic-Reboot` — a target that reboots itself
  mid-demonstration is worse than one a few days behind.

---

## `forge-health`

One command that answers "is this host in the state FORGE-AI intended?":

```bash
ssh forgeops@192.168.250.21 sudo forge-health
```

```text
FORGE-AI health: poc-ubuntu-01 -> ok (0 failing)
[  ok  ] hostname                 poc-ubuntu-01
[  ok  ] automation-user          forgeops exists
[  ok  ] service:ssh              active
[  ok  ] service:qemu-guest-agent active
[  ok  ] ssh-root-login           permitrootlogin no
[  ok  ] firewall                 Status: active
[  ok  ] desired-state            commit 0123456 applied 2026-01-01T10:22:00Z
```

`--json` for machine consumption. Used by the role's own validation, by
the smoke test, and available to any monitoring system.

---

## Customising

### A different Ubuntu release

```yaml
media:
  ubuntu:
    version: "22.04.5"
    codename: jammy
    iso_url: "https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
    iso_path: /srv/forge-ai/iso/ubuntu-22.04.5-live-server-amd64.iso
    iso_sha256: ""       # fetched from the official SHA256SUMS
```

On 22.04, cloud-init predates the `nocloud` rename — use `nocloud-net`
in the iPXE template.

### A static address instead of DHCP

Edit the `network` block in `ansible/templates/ubuntu/user-data.j2`:

```yaml
network:
  version: 2
  ethernets:
    primary:
      match: {macaddress: "{{ host.mac_address }}"}
      set-name: eth0
      addresses: ["{{ host.ip_address }}/{{ provisioning_network.cidr | prefix_from_cidr }}"]
      routes: [{to: default, via: "{{ provisioning_network.gateway }}"}]
      nameservers:
        addresses: {{ provisioning_network.dns_servers }}
```

The DHCP reservation already gives a deterministic address, so this is
only needed when there is no DHCP at all.

### An apt mirror or proxy

```yaml
media:
  ubuntu:
    apt_mirror: "http://mirror.internal/ubuntu"
provisioning_network:
  http_proxy: "http://proxy.internal:3128"
```

Both reach the installer and the installed system.

---

## Watching and debugging

```bash
virsh console poc-ubuntu-01                # the live installer, Ctrl+] to detach
make state
sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log
curl -s http://192.168.250.1:8080/api/state/52-54-00-25-00-21 | jq '.history'
```

On the target afterwards:

| Path | Contents |
|---|---|
| `/var/log/installer/subiquity-server-debug.log` | The autoinstall detail |
| `/var/log/forge-ai-installer/` | The same, preserved by a late-command |
| `/etc/forge-ai/state.json` | Which commit configured this host, and when |
| `/var/log/cloud-init.log` | Datasource discovery |

Validate a seed before booting anything:

```bash
curl -s http://192.168.250.1:8080/ubuntu/poc-ubuntu-01/user-data \
  | python3 -c 'import sys,yaml;print(yaml.safe_load(sys.stdin)["autoinstall"]["identity"])'
```

`docs/TROUBLESHOOTING.md` has the symptom-to-cause table.
