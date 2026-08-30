# Operations

Day-two: drift, reconciliation, reports, and the things that go wrong
after everything worked.

---

## Where a host is, right now

```bash
make state
```

```text
  poc-ubuntu-01    52-54-00-25-00-21  ready         attempts=1  updated=2026-01-01T10:22:04Z
  poc-windows-01   52-54-00-25-00-22  ready         attempts=2  updated=2026-01-01T10:48:11Z

  The state service stops offering an installer after 3 attempts.
  That is the reinstall-loop guard: a host at the limit is parked as 'failed'.
```

`attempts=2` on the Windows host is the kind of thing a green pipeline
hides and an operator wants to know.

Full history, including every dispatch decision:

```bash
./scripts/set-boot-state.sh poc-windows-01 --history
```

### The lifecycle

```text
new ──► installing ──► installed ──► configuring ──► ready
         │                                            │
         └──────────► failed ◄────────────────────────┘
                        │
                        └──► new   (operator resets; deliberate)
```

| State | Meaning | A network boot returns |
|---|---|---|
| `new` | Defined, never installed | The installer |
| `installing` | Installation in progress | The installer, attempts += 1 |
| `installed` | The OS is on disk | `sanboot` — local disk |
| `configuring` | Reachable, baseline being applied | `sanboot` |
| `ready` | Fully configured | `sanboot` |
| `failed` | Installation failed, or the attempt limit was reached | `sanboot` |

The service enforces the transitions: `ready → installing` is rejected
with 409, because it would mean a silent reinstall of a working machine.

### Changing it by hand

```bash
./scripts/set-boot-state.sh poc-ubuntu-01 new      # queues a REINSTALL — asks first
./scripts/set-boot-state.sh poc-ubuntu-01 ready    # after a manual repair
```

---

## Drift

```bash
make drift              # detect. Changes nothing.
make drift-report       # re-read the last report
make reconcile          # fix it, then prove it took
```

### Two sources, because neither is enough

| Source | Coverage | Reliability |
|---|---|---|
| Ansible check mode | Broad — everything the baselines manage | Depends on each module implementing check mode |
| Read-only compliance probes | Narrow — only what someone wrote a probe for | High: they read the live machine |

### Check-mode limitations, stated

This project does **not** claim that all Ansible modules have perfect
check-mode support. They do not:

| Module | Check-mode support | Consequence |
|---|---|---|
| `ansible.windows.win_shell` | **None** | Skipped entirely — invisible to a check-mode run |
| `ansible.windows.win_command` | **None** | Same |
| `ansible.windows.win_updates` | **None** | Patch posture invisible |
| `community.windows.win_security_policy` | Partial | May report no change when it would change |
| `ansible.builtin.command` / `shell` | None | `changed_when: false` hides them |

A check-mode-only report would be **silently blind** to SMBv1, the
firewall defaults, the PowerShell execution policy and the event log
sizing — every one of which this project manages with `win_shell`,
because there is no module for them.

Check mode also **over-reports on Linux**: a task that is effectively
idempotent but not perfectly so shows as "would change" on every run,
and a drift report that cries wolf is one nobody reads.

**So every control has a matching probe**, and the report labels each
finding with its source and records its blind spots:

```markdown
### poc-windows-01 — DRIFTED

- Changed resources (check mode): **0**
- Compliance probe failures: **1**

- **firewall-domain-profile** — expected `True`, observed `False`

> Check-mode blind spots on this host: ansible.windows.win_shell
> (no check-mode support), ansible.windows.win_updates (no check-mode
> support), community.windows.win_security_policy (partial).
```

The probe found what check mode could not. That is the point of having
both.

### Adding a probe

`ansible/inventories/poc/group_vars/{linux,windows}/main.yml`:

```yaml
forge_windows_probes:
  - name: rdp-denied
    command: "(Get-ItemProperty 'HKLM:\\System\\CurrentControlSet\\Control\\Terminal Server').fDenyTSConnections"
    expect: "1"
```

Each runs read-only and compares stdout to `expect`. Anything a shell
command can observe can be a probe.

### Reconciliation is manual, deliberately

`drift.auto_reconcile` is `false` and scheduled reconciliation is
opt-in. That is a position, not a missing feature.

The drift report says it plainly:

> If a deviation is legitimate, change the desired state in Git and open
> a pull request — **do not reconcile it away.**

Automatic reconciliation erases the evidence of what changed and why. A
change that *should* persist belongs in the repository; a change that
should not is worth understanding before it is reverted.

### Reconciliation verifies itself

`reconcile.yml` re-runs detection afterwards and **fails if drift
survives**. A reconcile that claims success without re-checking is an
assertion, not evidence.

If drift does survive, something on the host is fighting the desired
state — a competing configuration tool, a scheduled job, or a control
this project sets but does not own.

### Scheduling a drift check

In Semaphore: **Project → Schedules → New**, template `11 Detect drift`,
cron `0 */6 * * *`.

To make it alert, set `drift_fail_on_drift: true` in the template's
environment: the task goes red and the notification fires. Left `false`,
an operator running `make drift` gets a report rather than a stack
trace.

---

## Reports

```bash
make report                                   # the latest, human-readable
cat /srv/forge-ai/reports/latest.json | jq    # for automation
```

| Format | For |
|---|---|
| JSON | Automation and archival |
| Markdown | Humans, and pull request comments |
| HTML | Sharing; theme-aware, parses as strict XML |

### What is in it

Deployment ID · commit and branch · start, end, duration · operator ·
trigger · per-host OS, addressing, resources, provisioning /
configuration / validation results · **boot state and install attempt
count** · failed tasks · collected facts · source media with SHA-256 ·
component versions · log locations · a link to the Semaphore task.

### It reports on failed runs too

The `reporting` role only **assembles cacheable facts** published by the
roles that did the work. It never re-measures anything — which is what
lets it describe a run that partially failed, and a partially failed run
is when the report matters most.

Retention is `reporting.retain` (default 30). Reports are **never**
removed by any destroy target: they are the audit trail.

---

## Routine tasks

### Applying a configuration change

```bash
git checkout -b feat/increase-ubuntu-memory
$EDITOR config/poc.yml
make validate
git commit -am "feat(config): increase poc-ubuntu-01 to 8 GB"
git push -u origin feat/increase-ubuntu-memory
gh pr create
# review, merge; Gitea syncs; the webhook triggers validation
```

Then apply it:

```bash
make create-vms      # redefines the domain with the new resources
virsh shutdown poc-ubuntu-01 && virsh start poc-ubuntu-01
```

A memory change needs a power cycle, not a reboot: libvirt applies the
new definition at next boot.

### Adding a host

```yaml
hosts:
  - name: poc-ubuntu-02
    os_family: linux
    profile: ubuntu-server
    ip_address: 192.168.250.23      # outside the DHCP pool
    mac_address: "52:54:00:25:00:23" # locally administered, unique
    vcpu: 2
    memory_mb: 4096
    disk_gb: 40
```

```bash
make validate         # rejects duplicates, pool overlap, bad MACs
make deploy-pxe       # reservation, boot scripts, registry
make create-vms
make provision-ubuntu
make configure
```

`make validate` catches every mistake that would otherwise surface as a
mysterious PXE failure.

### Rebuilding one host

```bash
./scripts/set-boot-state.sh poc-ubuntu-01 new    # asks: this wipes the disk
virsh destroy poc-ubuntu-01 && virsh start poc-ubuntu-01
make state
```

The state reset is what makes the next network boot install rather than
`sanboot`.

### Updating the baseline

```bash
$EDITOR ansible/roles/ubuntu_baseline/tasks/...
make validate
make configure
make drift            # should report in sync
```

---

## Control plane

```bash
make ps
make logs SERVICE=state
make restart SERVICE=bootsrv
make down                    # stop, keeping volumes
make up
```

### Health

```bash
curl -s http://192.168.250.1:8080/healthz | jq          # boot server
curl -s http://192.168.250.1:8080/api/healthz | jq      # state service
curl -sk https://127.0.0.1:8443/ -H 'Host: gitea.poc.local' -o /dev/null -w '%{http_code}\n'
```

The state service health includes `known_hosts`, which should equal the
number in `config/poc.yml`. If it does not, `registry.json` is out of
step — re-run `make deploy-pxe`.

### Backing it up

There is **no backup automation**, and that is a documented limitation.
What matters:

```bash
# Gitea repositories and Semaphore history
docker run --rm -v forge-gitea-data:/data -v "$PWD:/backup" \
  alpine tar czf /backup/gitea-$(date +%F).tar.gz -C /data .
docker run --rm -v forge-semaphore-data:/data -v "$PWD:/backup" \
  alpine tar czf /backup/semaphore-$(date +%F).tar.gz -C /data .

# The database
docker compose exec database pg_dumpall -U forgepg > forge-db-$(date +%F).sql

# The secrets. Losing SEMAPHORE_ACCESS_KEY_ENCRYPTION makes every key
# in the Semaphore Key Store permanently undecryptable.
cp compose/.env .vault-password ~/secure-backup/
```

---

## Logs

| Component | Location |
|---|---|
| dnsmasq | `/srv/forge-ai/logs/dnsmasq.log`, `journalctl -u forge-dnsmasq` |
| Boot server | `/srv/forge-ai/logs/nginx/boot-access.log` |
| State service | `docker compose logs state` |
| Guest installers | `/srv/forge-ai/logs/guests/<host>/` |
| Ubuntu installer | On the target: `/var/log/installer/`, `/var/log/forge-ai-installer/` |
| Windows Setup | On the target: `C:\Windows\Panther\`, `C:\ProgramData\forge-ai\` |
| Semaphore | `docker compose logs semaphore`, plus the task history in the UI |
| libvirt / QEMU | `/var/log/libvirt/qemu/<domain>.log` |

Container logs are capped at 10 MB × 5 files. Host-side logs under
`/srv/forge-ai/logs/` are **not rotated** — add a logrotate rule for a
long-lived deployment:

```text
/srv/forge-ai/logs/*.log /srv/forge-ai/logs/nginx/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
```

`copytruncate` because dnsmasq and nginx hold their log files open.

---

## Diagnostics

```bash
# Where is everything?
make state
virsh list --all
virsh net-dhcp-leases gitops-provisioning
make ps

# The boot path
sudo tcpdump -i virbr-forge -n 'udp port 67 or udp port 68'
sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log
curl -s http://192.168.250.1:8080/state/52-54-00-25-00-21.ipxe

# Reachability, layer by layer
./scripts/wait-for-ssh.sh poc-ubuntu-01 --timeout 30
./scripts/wait-for-winrm.sh poc-windows-01 --timeout 60

# Ansible
cd ansible && ansible all -m ping
cd ansible && ansible windows -m ansible.windows.win_ping

# Certificates
openssl s_client -connect 192.168.250.22:5986 </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates -ext subjectAltName

# Integrity
./scripts/verify-checksums.sh
```

---

## Recovering from common situations

### A host is parked as `failed`

```bash
./scripts/set-boot-state.sh poc-windows-01 --history
ls /srv/forge-ai/logs/guests/poc-windows-01/
```

Find out **why** before resetting. The guard exists so that a broken
host stays broken visibly rather than reinstalling forever; resetting it
without diagnosing loses that.

### The state service lost its registry

```bash
curl -s http://192.168.250.1:8080/api/healthz | jq .known_hosts   # 0?
make deploy-pxe
```

`registry.json` must be readable by UID 10001 — the unprivileged user
the container runs as. If it is not, the service answers "unknown MAC"
for every host.

### An installed VM boots into the installer

Three layers, in order:

```bash
make state                                    # is it 'new'?
virsh dumpxml poc-ubuntu-01 | grep -A3 '<os'  # is 'hd' first?
virsh undefine poc-ubuntu-01 --nvram          # is the UEFI NVRAM stale?
```

The third is the one people miss: UEFI NVRAM keeps its own boot order
and survives a libvirt domain redefinition.

### Reconciliation does not stick

Something is fighting the desired state. Look for a competing
configuration tool, a scheduled task, or a Windows policy that reapplies
itself. `reconcile.yml` fails rather than reporting success, precisely
so this is visible.

---

## Tearing down

```bash
make destroy CONFIRM=DESTROY-POC        # VMs, disks, PXE, network
make destroy-all CONFIRM=DESTROY-POC    # also media and the control plane
./scripts/destroy.sh --all --volumes    # also the Gitea and Semaphore data
```

`--volumes` is separate because it destroys the audit trail. Deployment
reports and the downloaded ISOs are always kept.
