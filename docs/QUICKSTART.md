# Quickstart

Getting the PoC running without reading the rest of the repository.

**Time:** about 20 minutes of your attention, plus 30–60 minutes of
unattended installation.

---

## What you need

| Requirement | Minimum | Why |
|---|---|---|
| Ubuntu **24.04 LTS**, x86_64 | — | The only validated control host |
| Hardware virtualisation | `vmx` or `svm` in `/proc/cpuinfo` | Without KVM, Windows Setup takes hours instead of minutes |
| RAM | 16 GB | 12 GB for the two targets, 4 GB for the control plane |
| Free disk | 150 GB | qcow2 images plus ~15 GB of extracted Windows media |
| Root or sudo | — | libvirt, dnsmasq, `/srv`, Docker |
| Outbound HTTPS | — | The Ubuntu ISO and container images |

**Windows Server media is yours to supply.** Nothing from Microsoft is
in this repository. The Ubuntu target deploys perfectly well without it
— see [Ubuntu only](#ubuntu-only-if-you-have-no-windows-media).

> **Do not run this on a machine attached to a network you care about
> until you have read the DHCP warning below.**

---

## 1. Clone and configure

```bash
git clone https://github.com/danielesalpietro/FORGE-AI.git
cd FORGE-AI

cp compose/.env.example compose/.env
cp config/poc.example.yml config/poc.yml
```

Open `config/poc.yml`. Two things matter before anything else:

```yaml
provisioning_network:
  cidr: 192.168.250.0/24        # must NOT overlap any network this host uses
  gateway: 192.168.250.1

media:
  windows:
    iso_path: ""                # your Windows Server ISO, or leave empty
```

### The DHCP warning, in one paragraph

This project runs a DHCP server. It is bound to an **isolated libvirt
bridge** and nothing else, which is what makes it safe. But if you
change `provisioning_network` to a subnet that already exists on your
LAN, you will hand addresses to machines that have nothing to do with
this PoC, and the failure will be intermittent enough to get blamed on
something else. `make check` probes for a competing DHCP server before
anything is created; do not skip it.

---

## 2. Check the host

```bash
./bootstrap/check-prerequisites.sh
```

Read-only: it installs nothing and changes nothing. It runs 34 checks
and, for each failure, prints the command that fixes it.

If packages are missing:

```bash
./bootstrap/prepare-host.sh --install-docker
# then log out and back in, so libvirt/kvm group membership applies
```

`--install-docker` is a separate flag on purpose: installing a container
runtime rewrites the host's iptables rules and adds a root daemon. That
should be a decision, not a side effect.

Re-run the check until it says **READY**.

---

## 3. Bootstrap

```bash
./bootstrap/bootstrap.sh          # or: make bootstrap
```

About five minutes. It runs seven stages in dependency order:

| Stage | What it does |
|---|---|
| config | Ensures `config/poc.yml` exists and validates |
| secrets | Generates every credential, mode `0600` |
| prereq | Re-runs the host checks |
| network | Creates the isolated libvirt network |
| control-plane | Starts Gitea, Semaphore, PostgreSQL, the boot server |
| gitops | Creates the Gitea repository and the Semaphore project |
| verify | Confirms every endpoint answers |

Resumable if something fails:

```bash
./bootstrap/bootstrap.sh --resume-from control-plane
```

### Reaching the UIs

Gitea and Semaphore are published on **loopback** with a self-signed
certificate. From another machine:

```bash
ssh -L 8443:127.0.0.1:8443 you@kvm-host
```

and add to your `/etc/hosts`:

```text
127.0.0.1  gitea.poc.local semaphore.poc.local
```

Then `https://gitea.poc.local:8443` and
`https://semaphore.poc.local:8443`. Credentials are in `compose/.env`:

```bash
grep -E '^(GITEA|SEMAPHORE)_ADMIN' compose/.env
```

---

## 4. Prepare the media

```bash
make prepare-media
```

Downloads the Ubuntu ISO (~3 GB), verifies its SHA-256 against the
official `SHA256SUMS`, extracts the kernel and initrd, and — if you
supplied a Windows ISO — validates it, lists its editions and builds
WinPE with the VirtIO drivers injected.

### Choosing the Windows edition

```bash
make windows-images
```

```text
  [1] Windows Server 2025 SERVERSTANDARDCORE          6.2 GB
  [2] Windows Server 2025 SERVERSTANDARD              9.8 GB
  [3] Windows Server 2025 SERVERDATACENTERCORE        6.3 GB
  [4] Windows Server 2025 SERVERDATACENTER            9.9 GB
```

Copy the **exact name** into `config/poc.yml`:

```yaml
media:
  windows:
    image_name: "Windows Server 2025 SERVERSTANDARD"
```

**Index 1 is normally Server Core** — no desktop, no GUI tools. The
mistake only becomes visible after a 20-minute installation, which is
why this project refuses to guess.

---

## 5. Provision

```bash
make provision
```

Creates both VMs, network-boots them, and waits for each installation to
report completion.

| Target | Typical duration |
|---|---|
| Ubuntu | 8–15 minutes |
| Windows | 15–30 minutes |

### Watching it

In another terminal:

```bash
make state                      # lifecycle state and attempt count

virsh console poc-ubuntu-01     # the live Ubuntu installer (Ctrl+] to detach)
virt-viewer --connect qemu:///system poc-windows-01

sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log   # every artefact fetched
sudo journalctl -u forge-dnsmasq -f                     # what DHCP offered
```

`make state` is the most useful of these:

```text
  poc-ubuntu-01    52-54-00-25-00-21  installing    attempts=1  updated=2026-01-01T10:04:22Z
  poc-windows-01   52-54-00-25-00-22  installing    attempts=1  updated=2026-01-01T10:04:31Z
```

---

## 6. Configure and validate

```bash
make configure           # apply the baselines over SSH and WinRM
make validate-deployment # validation, idempotence check, deployment report
```

Then:

```bash
./scripts/smoke-test.sh
```

which verifies both machines by **reading them** rather than trusting a
playbook's exit code, and re-runs the configuration in check mode to
report whether anything would still change.

```bash
make report              # the human-readable deployment report
```

---

## 7. See drift work

The point of the whole exercise, in three commands:

```bash
# Break something by hand, the way a person actually would
ssh -i ~/.ssh/forge-ai-poc forgeops@192.168.250.21 \
  'echo "changed by hand" | sudo tee /etc/issue.net'

make drift               # detects it, changes nothing
make reconcile           # puts it back, then proves it took
```

The drift report will tell you it found the deviation **and** remind you
that if the change was legitimate, the fix is a pull request rather than
a reconcile.

`docs/DEMO-RUNBOOK.md` is the full 30–45 minute version.

---

## Ubuntu only, if you have no Windows media

Entirely supported. Leave `media.windows.iso_path` empty and the Windows
stages end cleanly:

```bash
make prepare-ubuntu-media
make provision-ubuntu
make configure ANSIBLE_ARGS="--limit linux"
make validate-deployment
```

Or remove the Windows host from `config/poc.yml` altogether, which also
halves the RAM requirement.

---

## Tearing it down

```bash
make destroy CONFIRM=DESTROY-POC        # VMs, disks, PXE services, network
make destroy-all CONFIRM=DESTROY-POC    # also media and the control plane
```

Deployment reports are **never** removed — they are the audit trail. The
downloaded ISOs are kept too; re-downloading several gigabytes to
rebuild is rarely what anyone wants.

---

## When something goes wrong

Start here:

```bash
make state                                    # where is each host?
curl -s http://192.168.250.1:8080/api/state | jq
docker compose --env-file compose/.env -f compose/docker-compose.yml ps
sudo tail -50 /srv/forge-ai/logs/nginx/boot-access.log
```

Then [TROUBLESHOOTING.md](TROUBLESHOOTING.md), which maps each symptom
to the layer that produced it. The five most common:

| Symptom | Usually |
|---|---|
| VM sits at "PXE-E53: no boot filename received" | dnsmasq is not running, or is bound to the wrong interface |
| iPXE loads, then loads iPXE again, forever | A `dhcp-boot` rule lost its `tag:!ipxe` |
| Ubuntu installer waits at a prompt | The seed URL is missing its trailing slash |
| Windows Setup: "We couldn't find any drives" | The `viostor` driver path is wrong for this virtio-win release |
| Windows installed but Ansible cannot connect | `SetupComplete.cmd` did not run; re-run `Configure-WinRM.ps1` from the console |

---

## The whole thing, in one block

```bash
git clone https://github.com/danielesalpietro/FORGE-AI.git && cd FORGE-AI
cp compose/.env.example compose/.env
cp config/poc.example.yml config/poc.yml
$EDITOR config/poc.yml                   # set media.windows.iso_path

make check
./bootstrap/prepare-host.sh --install-docker   # if the check asked for it
# log out and back in

make bootstrap
make windows-images                      # copy the edition name into config/poc.yml
make prepare-media
make provision
make configure
make validate-deployment
./scripts/smoke-test.sh
make report
```
