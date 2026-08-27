# Troubleshooting

Symptom, cause, fix. Ordered by where in the lifecycle the failure
appears.

## Start here

Four commands answer most questions before you read any further:

```bash
make state                                       # where is each host?
curl -s http://192.168.250.1:8080/api/state | jq # full history, per host
docker compose --env-file compose/.env -f compose/docker-compose.yml ps
sudo tail -50 /srv/forge-ai/logs/nginx/boot-access.log
```

The boot access log is the single most useful artefact: it shows every
file a booting machine asked for, in order, with the status code. A 404
in it usually *is* the answer.

---

## Network boot

### PXE client receives no DHCP response

```text
PXE-E53: No boot filename received
>>Checking Media Presence......
>>Media Present......
>>Start PXE over IPv4
```

**Diagnose:**

```bash
sudo systemctl status forge-dnsmasq
sudo ss -lnup 'sport = :67'
sudo tcpdump -i virbr-forge -n 'udp port 67 or udp port 68'
```

| Cause | Fix |
|---|---|
| dnsmasq is not running | `sudo journalctl -u forge-dnsmasq -n 50` — usually a config error it refused to start on |
| The config is invalid | `sudo dnsmasq --test --conf-file=/etc/forge-ai/dnsmasq.conf` |
| Bound to the wrong interface | Check `interface=` and `listen-address=` match `provisioning_network.bridge` and `.gateway` |
| The bridge does not exist | `virsh net-list --all`, then `make deploy-pxe` |
| The VM is on a different network | `virsh domiflist poc-ubuntu-01` — the source must be `gitops-provisioning` |
| The MAC has no reservation | `grep dhcp-host /etc/forge-ai/dnsmasq.conf` |

If `tcpdump` shows the DISCOVER arriving but no OFFER, dnsmasq is
running but rejecting the client — check the reservation. If no DISCOVER
arrives at all, the VM is not on this bridge.

---

### iPXE chainloading loop

iPXE loads, prints its banner, then loads iPXE again, forever.

**Cause.** A `dhcp-boot` rule that hands over a binary lost its
`tag:!ipxe`. iPXE asks DHCP, is told to load iPXE, and repeats.

**Fix.** Every "give it a binary" rule must carry `tag:!ipxe`:

```bash
grep dhcp-boot /etc/forge-ai/dnsmasq.conf
```

```text
dhcp-boot=tag:bios,tag:!ipxe,undionly.kpxe,boot.poc.local,192.168.250.1
dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi,boot.poc.local,192.168.250.1
dhcp-boot=tag:ipxe,http://192.168.250.1:8080/boot/boot.ipxe
```

The last line is the only one without `tag:!ipxe`, and it serves a
*script*, not a binary. Also confirm the detection rules are present:

```text
dhcp-match=set:ipxe,175
dhcp-userclass=set:ipxe,iPXE
```

Re-render and restart:

```bash
make deploy-pxe
sudo systemctl restart forge-dnsmasq
```

---

### UEFI client cannot load the boot binary

```text
PXE-E23: Client received TFTP error from server
```

or the firmware hangs after "Start PXE over IPv4".

| Cause | Fix |
|---|---|
| `ipxe.efi` is not in the TFTP root | `ls -la /srv/forge-ai/tftp/` then `./scripts/download-ipxe-assets.sh` |
| The BIOS binary was served to a UEFI client | Check `dhcp-match=set:efi64,option:client-arch,7` and `,9` are both present |
| TFTP is not listening | `sudo ss -lnup 'sport = :69'` |
| The file is unreadable | `sudo chmod 0644 /srv/forge-ai/tftp/*` |
| Secure Boot is on | The PoC's iPXE is unsigned. Disable it, or see `docs/SECURITY.md`, "unsigned boot components". |

Test TFTP directly from the host:

```bash
tftp 192.168.250.1 -c get ipxe.efi /tmp/ipxe.efi && ls -la /tmp/ipxe.efi
```

---

### The VM boots into the installer again after installing

**Diagnose first** — this is the reinstall-loop guard's territory:

```bash
make state
curl -s http://192.168.250.1:8080/api/state/52-54-00-25-00-21 | jq
```

| Observed state | Meaning | Fix |
|---|---|---|
| `installing`, attempts at the limit | The guard stopped it. It is now booting local disk. | Find out **why the install failed** before resetting |
| `new` | The state was reset, deliberately or otherwise | `./scripts/set-boot-state.sh <host> installed` if it really is installed |
| `installed` but it still net-boots | The libvirt boot order or the UEFI NVRAM | See below |

**libvirt boot order:**

```bash
virsh dumpxml poc-ubuntu-01 | grep -A3 '<os'
```

`<boot dev='hd'/>` should come first. If not:

```bash
cd ansible && ansible-playbook playbooks/provision-ubuntu.yml --tags provisioning
```

**UEFI NVRAM** keeps its own boot order, independently of libvirt. If
the domain says `hd` first and the VM still network-boots, the guest's
NVRAM is overriding it:

```bash
virsh destroy poc-ubuntu-01
virsh undefine poc-ubuntu-01 --nvram      # discards the NVRAM
cd ansible && ansible-playbook playbooks/create-vms.yml
```

Note `--nvram`. Without it the stale variable store survives, which is
exactly why `destroy.yml` passes it.

---

### Conflicting DHCP server

```text
[ERROR] dhcp-conflict: DHCP server(s) other than the FORGE-AI one
answered on virbr-forge: 192.168.1.1
```

**This is the check working.** Two DHCP servers on one segment make PXE
fail intermittently and can hand addresses to machines outside the PoC.

```bash
sudo tcpdump -i virbr-forge -n 'udp port 67 or udp port 68'
```

| Cause | Fix |
|---|---|
| The bridge is connected to a physical LAN | Use `forward_mode: nat`, not `bridge` |
| libvirt started its own dnsmasq | `ls /var/lib/libvirt/dnsmasq/` — the network XML must have `<dns enable="no"/>` and no `<dhcp>` |
| A previous FORGE-AI dnsmasq is still running | `sudo systemctl status forge-dnsmasq`, `ps aux \| grep dnsmasq` |
| The packaged dnsmasq is enabled | `sudo systemctl disable --now dnsmasq` |

Only override with `-e forge_force=true` when you are certain.

---

## Ubuntu installation

### The installer waits for interaction

The console shows the Subiquity menu instead of installing.

**Cause, nine times out of ten: the seed URL is missing its trailing
slash.** cloud-init appends the filenames verbatim, so
`s=http://…/poc-ubuntu-01` requests `…poc-ubuntu-01user-data` and gets
a 404.

```bash
curl -I http://192.168.250.1:8080/ubuntu/poc-ubuntu-01/user-data
sudo grep -i 'user-data\|404' /srv/forge-ai/logs/nginx/boot-access.log | tail
```

| Cause | Fix |
|---|---|
| Missing trailing slash | Check `ds=nocloud;s=` in `/srv/forge-ai/http/boot/host-*-install.ipxe` — it must end with `/` |
| The seed was purged | It is removed after a successful install. `make deploy-pxe` re-renders it. |
| The seed is malformed | `curl -s …/user-data \| python3 -c 'import sys,yaml;yaml.safe_load(sys.stdin)'` |
| `autoinstall` missing from the cmdline | Check the rendered iPXE script |

On the target afterwards:
`/var/log/installer/subiquity-server-debug.log`.

---

### Ubuntu cannot retrieve user-data

```text
cloud-init: failed to fetch the datasource
```

```bash
curl -v http://192.168.250.1:8080/ubuntu/poc-ubuntu-01/user-data
docker compose --env-file compose/.env -f compose/docker-compose.yml ps bootsrv
```

| Cause | Fix |
|---|---|
| The boot server is down | `make deploy-control-plane` |
| The VM has no address | `virsh net-dhcp-leases gitops-provisioning` |
| `ip=dhcp` missing from the cmdline | Check the rendered iPXE script |
| Wrong datasource spelling | The PoC uses `ds=nocloud;s=`. On cloud-init < 23.10, `nocloud-net` is needed instead. |

---

### The installer starts but cannot download the ISO

casper needs the ISO itself over HTTP.

```bash
curl -I http://192.168.250.1:8080/iso/ubuntu-24.04.3-live-server-amd64.iso
ls -la /srv/forge-ai/http/iso/
```

If it is missing, `make prepare-ubuntu-media`. If the file exists but
returns 404, the hard link into `http/iso/` failed — the role falls back
to a copy, so re-run the media playbook.

---

## Windows installation

### Windows cannot load the VirtIO disk

```text
We couldn't find any drives. To get a storage driver, click Load driver.
```

or, in WinPE, `diskpart` reports "There are no fixed disks to show".

**Cause.** The `viostor` driver was not loaded. Windows has no in-box
VirtIO driver.

```bash
wimlib-imagex dir /srv/forge-ai/http/windows/boot-forge.wim 2 | grep -i forge
ls /srv/forge-ai/http/windows/virtio/viostor/
```

| Cause | Fix |
|---|---|
| Drivers not injected into WinPE | `./scripts/build-winpe.sh --force` |
| Wrong driver path for this virtio-win release | The `2k25`/`2k22`/`w11` sub-directory names change between releases. `ls /srv/forge-ai/http/windows/virtio/viostor/` and correct `media.windows.virtio.driver_paths`. |
| The SMB export is unreachable, so Setup's `DriverPaths` failed | `smbclient -N -L //192.168.250.1` |

**Fallback:** attach the VirtIO ISO as a CD-ROM so Setup can load
drivers without the network:

```bash
cd ansible && ansible-playbook playbooks/create-vms.yml \
  -e windows_attach_virtio_cdrom=true
```

---

### Windows Setup cannot retrieve the installation files

WinPE fails at step 3 of `startnet.cmd`.

```bash
smbclient -N -L //192.168.250.1
docker compose --env-file compose/.env -f compose/docker-compose.yml --profile windows ps winmedia
ls -la /srv/forge-ai/http/windows/media/sources/
```

| Cause | Fix |
|---|---|
| The SMB container is not running | `docker compose --profile windows up -d winmedia` |
| The media was never extracted | `make prepare-windows-media` |
| No network in WinPE | `NetKVM` was not injected — see the previous entry |
| Port 445 is taken by a host Samba | `sudo ss -lntp 'sport = :445'` |

Read `X:\forge-ai.log` on the WinPE console: it logs each of the six
steps and which one failed.

---

### The wrong Windows edition was installed

Server Core when you expected the desktop, or vice versa.

**Cause.** Index 1 on a Server ISO is normally Standard **Core**.

```bash
make windows-images
```

Copy the exact name into `config/poc.yml`:

```yaml
media:
  windows:
    image_name: "Windows Server 2025 SERVERSTANDARD"
```

Then rebuild:

```bash
make prepare-windows-media
./scripts/set-boot-state.sh poc-windows-01 new     # queues a reinstall
make provision-windows
```

The `windows_media` role fails **with the available list** if the
configured edition is not in the image, so this should be caught before
any installation starts.

---

### WinRM listener unavailable

The VM installed, answers ping, but nothing on 5986.

```bash
./scripts/wait-for-winrm.sh poc-windows-01 --timeout 60
```

That script probes TCP, then TLS, then WS-Man separately and tells you
which layer failed — the three have very different causes.

**Cause, most often: `SetupComplete.cmd` did not run.**

From the VM console (`virt-viewer --connect qemu:///system
poc-windows-01`), log in as Administrator and:

```powershell
Get-Content C:\ProgramData\forge-ai\setupcomplete.log
powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\Configure-WinRM.ps1
```

`Configure-WinRM.ps1` is deliberately **not** purged after installation,
precisely so this recovery is a one-liner.

| Cause | Fix |
|---|---|
| The specialize pass could not download the scripts | Check the boot access log for `/windows/<host>/SetupComplete.cmd` |
| `Configure-WinRM.ps1` failed | Read the log above; it reports each step |
| The firewall rule is too narrow | `Get-NetFirewallRule -Name FORGE-AI-WinRM-HTTPS-In \| Get-NetFirewallAddressFilter` |
| Setup left the account with no password | The password failed the complexity policy. `windows_unattend` checks this before rendering, so it should not happen. |

---

### TLS certificate validation failure

```text
certificate verify failed: self signed certificate
```

**Expected** if you set `security.winrm_cert_validation: validate`
without first enrolling the certificate. The PoC certificate is
generated self-signed during specialize.

Either set it back to `ignore` (the documented PoC default), or export
the target's certificate and trust it:

```bash
openssl s_client -connect 192.168.250.22:5986 </dev/null 2>/dev/null \
  | openssl x509 > /usr/local/share/ca-certificates/poc-windows-01.crt
sudo update-ca-certificates
```

`docs/SECURITY.md` covers moving to a CA-issued certificate.

---

## Ansible

### SSH failure to the Ubuntu target

```bash
./scripts/wait-for-ssh.sh poc-ubuntu-01 --timeout 60
```

Layered diagnosis again: ICMP, then TCP, then authentication.

| Cause | Fix |
|---|---|
| Wrong key | `ssh-keygen -lf ~/.ssh/forge-ai-poc.pub` and compare with `security.ssh_authorized_keys` in `config/poc.yml` |
| The key was never authorised | It must be in `config/poc.yml` **before** the install renders the seed |
| Wrong user | The default is `forgeops`, from `users.automation_user` |
| ufw is blocking your source | The rule is scoped to `security.management_cidrs` |
| The host is still installing | `make state` |

### Semaphore cannot clone the Gitea repository

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml logs semaphore | tail -30
docker compose --env-file compose/.env -f compose/docker-compose.yml exec semaphore \
  sh -c 'git ls-remote http://gitea:3000/forge-ai/gitops-infrastructure.git'
```

| Cause | Fix |
|---|---|
| The wrong URL | Semaphore reaches Gitea over the **Docker network**: `http://gitea:3000/...`, not the proxied hostname |
| The repository does not exist | Re-run `ansible-playbook playbooks/bootstrap-control-plane.yml --tags gitops` |
| The mirror has not synced | Gitea pulls on `GITEA_MIRROR_INTERVAL`; force it in the UI under Settings → Mirror |
| The repository is private with no credential | Add a Gitea token to the Semaphore repository entry |

### Webhook signature failure

```text
rejected webhook from 172.28.240.5: bad or missing HMAC signature
```

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml logs webhook | tail
```

The secret must match in **both** places:

```bash
grep FORGE_WEBHOOK_SECRET compose/.env
ansible-vault view --vault-password-file .vault-password \
  ansible/inventories/poc/group_vars/all/vault.yml | grep webhook
```

If they differ, update the Gitea webhook (Settings → Webhooks) and
restart the receiver.

An empty `FORGE_WEBHOOK_SECRET` rejects **every** request, by design —
the alternative would be accepting all of them.

---

## Host and hypervisor

### libvirt permission denied

```text
error: Failed to create domain
error: Cannot access storage file ... Permission denied
```

```bash
ls -la /var/lib/libvirt/images/
id
```

| Cause | Fix |
|---|---|
| Disk not owned by `libvirt-qemu:kvm` | `sudo chown libvirt-qemu:kvm /var/lib/libvirt/images/*.qcow2` |
| Not in the `libvirt` group | `sudo usermod -aG libvirt,kvm $USER`, then **log out and back in** |
| A parent directory is not traversable | Every directory in the path needs `o+x` |
| AppArmor | `sudo dmesg \| grep -i apparmor \| tail` |

Group membership does not apply to the session that ran `usermod`. This
catches everyone once.

### Insufficient RAM or disk

```bash
./bootstrap/check-prerequisites.sh
free -h
df -h /srv /var/lib/libvirt
```

The requirements are computed from `config/poc.yml`, not hardcoded — so
reducing `memory_mb` or `disk_gb`, or removing the Windows host, changes
what the check demands.

qcow2 images are sparse: a 40 GB disk uses far less until it is filled.
Extracted Windows media needs about 15 GB and is not sparse.

### The control plane will not start

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml ps
docker compose --env-file compose/.env -f compose/docker-compose.yml logs --tail=50
```

| Symptom | Cause |
|---|---|
| `required variable X is missing a value` | Run `./bootstrap/create-secrets.sh` |
| `cannot assign requested address` on `bootsrv` | The bridge does not exist yet. Create the network **before** the stack: `make deploy-pxe` then `make deploy-control-plane`. |
| `port is already allocated` | Something else holds 8080 or 445: `sudo ss -lntp` |
| Semaphore restarts repeatedly | `SEMAPHORE_ACCESS_KEY_ENCRYPTION` must be exactly 32 raw bytes, base64-encoded |
| Gitea cannot reach the database | `docker compose logs database` — the init script needs the password variables |

---

## Getting more detail

```bash
# Ansible, with the task that failed and why
cd ansible && ansible-playbook playbooks/site.yml -vvv

# Every artefact a booting machine requested
sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log

# What dnsmasq decided, per request
sudo journalctl -u forge-dnsmasq -f

# The full lifecycle history of a host, including every dispatch
curl -s http://192.168.250.1:8080/api/state/52-54-00-25-00-21 | jq '.history'

# Logs a guest uploaded before it failed
ls -la /srv/forge-ai/logs/guests/*/

# QEMU's own view
sudo tail -50 /var/log/libvirt/qemu/poc-windows-01.log
```

## If none of this helps

Open an issue with the output of:

```bash
./bootstrap/check-prerequisites.sh --json
make state
make version
```

The issue template asks for exactly these. Redact anything sensitive
first — the state output is safe, the others may name paths.
