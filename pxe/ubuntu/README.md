# `pxe/ubuntu/`

The Ubuntu Server network installation path.

## There is no netboot image for 24.04 Server

This is the fact that shapes everything else here. Ubuntu stopped
shipping `netboot.tar.gz` for Server; the supported network path is:

1. boot `casper/vmlinuz` and `casper/initrd`, **extracted from the ISO**;
2. pass `url=<http url to the ISO>` on the kernel command line, so
   casper fetches the ISO itself and finds the squashfs inside it.

That is why `ubuntu_media` extracts exactly two files and then publishes
the whole 3 GB ISO over HTTP. It is not a shortcut; it is the mechanism.

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
  net.ifnames=0 fsck.mode=skip \
  console=tty0 console=ttyS0,115200n8 \
  ---
```

| Parameter | Why |
|---|---|
| `ip=dhcp` | casper needs an address before it can fetch anything |
| `url=` | where casper gets the ISO, and therefore the squashfs |
| `autoinstall` | tells Subiquity to run unattended |
| `ds=nocloud;s=` | the seed directory — **note the trailing slash** |
| `cloud-config-url=/dev/null` | stops cloud-init picking up a datasource from elsewhere |
| `console=ttyS0` | makes `virsh console` show the installer |
| `---` | everything after this is passed to the installed system |

### The trailing slash

cloud-init appends the filenames to the `s=` value **verbatim**. Without
the trailing slash it requests `.../poc-ubuntu-01user-data`, gets a 404,
finds no datasource, and drops to an interactive prompt — which on a
headless VM is indistinguishable from a hang.

It is the single most common Ubuntu PXE failure, and
`tests/unit/test_ipxe_selection.py` asserts the slash is there.

### `nocloud` rather than `nocloud-net`

cloud-init 24.x deprecated `nocloud-net`. `ds=nocloud;s=http://…` with
an HTTP seed does the same thing and is the current spelling. If you are
adapting this for an older release, `nocloud-net` still works —
`docs/TROUBLESHOOTING.md` covers the symptom either way.

## The seed

Three files, rendered per host by the `ubuntu_autoinstall` role:

| File | Purpose |
|---|---|
| `user-data` | The autoinstall answer file |
| `meta-data` | `instance-id` and `local-hostname`. cloud-init needs it to exist; a changed `instance-id` is what tells it this is a genuinely new machine and not a reboot |
| `vendor-data` | Empty. It exists because a missing one logs a 404, which is noise during a demonstration |

`user-data` carries a **crypt(3) hash**, never a cleartext password: it
is served over HTTP *and* ends up in `/var/log/installer` on the target.
The role asserts the hash format before rendering.

## The callback that stops a reinstall loop

The seed's `late-commands` include:

```bash
curl -X POST -d '{"state":"installed",...}' \
  http://192.168.250.1:8080/api/state/52-54-00-25-00-21
```

That is the installer telling the state service it finished, so the
reboot that follows lands on the local disk instead of back in the
installer. `error-commands` reports `failed` and uploads
`/var/log/installer` for diagnosis.

An `efibootmgr` late-command sets the guest's own UEFI boot order too —
belt and braces, because NVRAM survives a libvirt domain redefinition.

## Watching an installation

```bash
virsh console poc-ubuntu-01              # Ctrl+] to detach
sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log
curl -s http://192.168.250.1:8080/api/state/52-54-00-25-00-21 | jq
```

On the target afterwards: `/var/log/installer/subiquity-server-debug.log`
has the autoinstall detail, and the role copies the whole directory to
`/var/log/forge-ai-installer/` so it survives.
