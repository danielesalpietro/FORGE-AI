# Demonstration runbook

A 30–45 minute walkthrough of the whole lifecycle, for an audience.

---

## Before anyone is watching

Do all of this beforehand. The interesting parts are the boot and the
drift loop, not watching a 3 GB download.

```bash
make check                    # must say READY
make bootstrap                # ~5 min
make prepare-media            # ~10 min, mostly downloading
make windows-images           # confirm the edition name is right
```

Then destroy just the VMs, so the demonstration starts from nothing:

```bash
make destroy CONFIRM=DESTROY-POC
```

The control plane, the network and the media stay. You will build the
machines live.

### Terminals to have open

| # | Purpose | Command |
|---|---|---|
| 1 | Driving | the repository root |
| 2 | State | `watch -n2 './scripts/set-boot-state.sh'` |
| 3 | Boot traffic | `sudo tail -f /srv/forge-ai/logs/nginx/boot-access.log` |
| 4 | Ubuntu console | `virsh console poc-ubuntu-01` (once it exists) |
| 5 | Windows console | `virt-viewer --connect qemu:///system poc-windows-01` |

Terminal 3 is the one people find most convincing: they watch a machine
that does not yet have an operating system fetch, in order, a boot
script, a kernel, an initrd and its own answer file.

### Browser tabs

- `https://gitea.poc.local:8443` — logged in
- `https://semaphore.poc.local:8443` — on the task list
- The GitHub repository, on a pull request

Reachable through an SSH tunnel if the KVM host is remote:

```bash
ssh -L 8443:127.0.0.1:8443 you@kvm-host
```

---

## 1 · The desired state is a file (3 min)

> "Everything about these two machines is one file in Git. Nothing is
> configured by hand, and nothing is remembered anywhere else."

```bash
sed -n '/^hosts:/,/^security:/p' config/poc.yml
```

Point out: names, addresses, MACs, resources. Nothing about *how* — only
*what*.

```bash
make validate
```

> "That is the schema, plus the rules a schema cannot express."

Now break it deliberately:

```bash
# Give both hosts the same address
sed -i 's/192.168.250.22/192.168.250.21/' config/poc.yml
make validate-config
```

```text
[ERROR  ] hosts[1].ip_address: duplicate IP address 192.168.250.21
```

```bash
git checkout config/poc.yml
```

> "That runs on every pull request. An invalid desired state cannot
> reach a machine — the inventory itself refuses to build."

---

## 2 · Nothing unreviewed deploys (4 min)

Show the GitHub pull request. Point at:

- the three required checks — lint, validate, security;
- CODEOWNERS requesting review on the boot chain and the answer files;
- the branch protection rules.

> "Semaphore does not read GitHub. It reads Gitea, and Gitea mirrors
> `main`. A feature branch cannot reach a machine even if someone
> triggers a task by hand."

Show the Gitea repository, then Semaphore's thirteen templates.

> "Template 99 destroys everything. It is numbered to sort last, it
> needs a typed confirmation, and the playbook checks the same token
> again on the Ansible side — because a UI control is not a security
> boundary."

---

## 3 · Build the machines (2 min to start)

```bash
make create-vms
```

Switch to **terminal 3**. Within seconds:

```text
"GET /boot/boot.ipxe HTTP/1.1" 200
"GET /state/52-54-00-25-00-21.ipxe HTTP/1.1" 200
"GET /boot/host-52-54-00-25-00-21-install.ipxe HTTP/1.1" 200
"GET /ubuntu/casper/vmlinuz HTTP/1.1" 200
"GET /ubuntu/casper/initrd HTTP/1.1" 200
"GET /ubuntu/poc-ubuntu-01/user-data HTTP/1.1" 200
```

> "That machine has no operating system. It is asking the network what
> to be."

Switch to **terminal 2**:

```text
poc-ubuntu-01    52-54-00-25-00-21  installing  attempts=1
poc-windows-01   52-54-00-25-00-22  installing  attempts=1
```

---

## 4 · Watch the installations (5 min, then leave them)

**Terminal 4** — Subiquity, on a serial console:

```bash
virsh console poc-ubuntu-01
```

**Terminal 5** — WinPE, then Windows Setup:

```bash
virt-viewer --connect qemu:///system poc-windows-01
```

Worth narrating while they run:

> "The Windows machine booted WinPE over the network. WinPE has no
> VirtIO driver, so it would see no disk and no network — we injected
> them into the boot image, on Linux, with `wimlib-imagex`. No Windows
> machine involved."

And, if anyone asks where the credentials are:

> "Its answer file was never written to the file share. wimboot injected
> it straight into WinPE's `System32`, because it carries the
> administrator password."

This is a good moment for questions. Ubuntu takes 8–15 minutes, Windows
15–30.

---

## 5 · The reinstall-loop guard (3 min, while waiting)

> "The obvious failure of a system like this is a machine that fails
> halfway through installing and then reinstalls forever. It looks
> *busy* rather than *broken*, so nobody investigates."

```bash
curl -s http://192.168.250.1:8080/state/52-54-00-25-00-21.ipxe
```

```text
#!ipxe
# FORGE-AI state service: poc-ubuntu-01 is installing
# attempt 2 of 3
```

> "Every network boot increments a counter. Past the limit the service
> stops offering the installer and parks the host as `failed`. The
> libvirt boot order is flipped to local disk as a second, independent
> guard — if the state service vanished entirely, an installed machine
> would still come up on its own disk."

```bash
python3 -m pytest tests/unit/test_ipxe_selection.py -q
```

> "Thirty-four tests, and none of them needs a hypervisor."

---

## 6 · The machines are real (4 min)

```bash
make state          # both ready
make configure      # applies the baselines over SSH and WinRM
```

```bash
./scripts/smoke-test.sh
```

> "That reads the machines rather than trusting a playbook's exit code.
> Hostname, services, SSH policy, firewall, SMBv1, the WinRM
> certificate."

Then:

```bash
ssh -i ~/.ssh/forge-ai-poc forgeops@192.168.250.21 sudo forge-health
```

```text
FORGE-AI health: poc-ubuntu-01 -> ok (0 failing)
[  ok  ] desired-state   commit 0123456 applied 2026-01-01T10:22:00Z
```

> "The machine knows which commit configured it."

---

## 7 · Drift, detection and reconciliation (8 min)

**This is the part that matters.** Everything before it was
provisioning; this is what makes it GitOps.

### Break both machines by hand

```bash
ssh -i ~/.ssh/forge-ai-poc forgeops@192.168.250.21 \
  'echo "Nobody will notice this" | sudo tee /etc/issue.net'
```

```bash
cd ansible && ansible poc-windows-01 -m ansible.windows.win_shell \
  -a "New-NetFirewallRule -DisplayName 'FORGE-AI-Drift-Demo' -Direction Inbound -Action Allow -LocalPort 8888 -Protocol TCP" \
  --vault-password-file ../.vault-password
cd ..
```

> "Two changes an engineer might genuinely make at 2am. Neither is in
> Git."

### Detect

```bash
make drift
```

```text
================================================================
 DRIFT DETECTED -- 2 of 2 host(s)
================================================================

  poc-ubuntu-01 (linux): DRIFTED
    check-mode changes : 1
    probe failures     : 1
      - login-banner: expected "FORGE-AI Proof of Concept system...",
                      observed "Nobody will notice this"

  poc-windows-01 (windows): DRIFTED
    probe failures     : 1
      - firewall-rule-count: expected "4", observed "5"

  blind spots on poc-windows-01: ansible.windows.win_shell
  (no check-mode support), ansible.windows.win_updates
```

Two things to point at:

> "It found both. And notice the last line — it tells you where it
> **cannot** see. `win_shell` has no check-mode support at all, so a
> check-mode-only report would be silently blind to SMBv1, the firewall
> defaults and the execution policy. That is why every control also has
> a read-only probe."
>
> "A drift report that overstates its coverage is worse than none."

### Reconcile

```bash
make reconcile
```

> "Detection changed nothing. Reconciliation is a separate, deliberate
> step — and it re-runs detection afterwards and **fails** if drift
> survives. A reconcile that claims success without re-checking is an
> assertion, not evidence."

```bash
make drift          # in sync
ssh -i ~/.ssh/forge-ai-poc forgeops@192.168.250.21 cat /etc/issue.net
```

### The point

> "The report says something worth reading: *if a deviation is
> legitimate, change the desired state in Git and open a pull request —
> do not reconcile it away.*
> Automatic reconciliation erases the evidence of what changed. If that
> firewall rule was needed, the fix is a pull request, not a revert."

---

## 8 · The audit trail (4 min)

```bash
make report
```

Point at: deployment ID, commit, operator, trigger, per-host results,
**install attempt count**, media SHA-256, component versions.

> "Two attempts on the Windows host. A green pipeline hides that; this
> does not."

Open the HTML report — it is theme-aware and parses as strict XML, so
tooling can consume it.

In Semaphore, show the task history:

> "Every run, who started it, which commit, the full output. That is the
> audit trail, and it is why the destroy targets never delete the
> reports."

---

## 9 · Tear down (2 min)

```bash
make destroy CONFIRM=DESTROY-POC
```

> "It refuses without the token. Then the script prints exactly what
> goes and what stays and asks you to type it. Then the playbook checks
> the same token again — three independent confirmations, because
> someone calling the Semaphore API directly bypasses the first two."

```bash
ls /srv/forge-ai/reports/
```

> "The reports survive. They are the audit trail."

---

## Questions that come up

**"How long from empty to running?"**
About 45 minutes wall-clock for both, mostly unattended. Around 10
minutes of that is the operator's attention.

**"What if the Windows media is unavailable?"**
The Windows stages end cleanly and the Ubuntu target deploys. Nothing
from Microsoft is in this repository — it is the operator's to supply,
under their licence.

**"Is this production-ready?"**
No, and `docs/LIMITATIONS.md` says exactly why. The largest gaps: Secure
Boot is off, WinRM uses a self-signed certificate, and there is one
shared local administrator password because there is no domain.
`docs/SECURITY.md` has each threat with its production alternative.

**"What does CI actually test?"**
Everything except deploying. Schema, semantics, all 21 templates
rendered and parsed, `Autounattend.xml` checked pass by pass, Ansible
syntax, 204 unit tests, 29 shell tests, secret scanning, Trivy. No VM is
created — GitHub runners have no nested virtualisation. The end-to-end
workflow exists and is disabled, so the gap stays checkable.

**"Can it do bare metal?"**
The boot chain is already the hard part and would work. What is missing
is out-of-band power control — Redfish or IPMI — to make a physical
machine PXE-boot on demand. It is on the roadmap.

**"Why Gitea as well as GitHub?"**
So the deployment source is inside the perimeter and read-only. With the
default mirror strategy GitHub holds **no** Gitea credential, so a
compromised Actions runner cannot push to what Semaphore deploys.

---

## If something fails live

Stay calm; the failure modes are documented and that is itself worth
showing.

```bash
make state          # where is it?
sudo tail -20 /srv/forge-ai/logs/nginx/boot-access.log
```

> "Let me show you what the troubleshooting guide says about this."

Open `docs/TROUBLESHOOTING.md` at the matching symptom. A project that
anticipated the failure is more convincing than one that never hits it.

If a machine is genuinely stuck:

```bash
./scripts/set-boot-state.sh poc-ubuntu-01 new
virsh destroy poc-ubuntu-01 && virsh start poc-ubuntu-01
```

---

## Timing

| Section | Minutes |
|---|---|
| 1 · Desired state | 3 |
| 2 · Review gate | 4 |
| 3 · Build | 2 |
| 4 · Watch the installs | 5 (then background) |
| 5 · Loop guard | 3 |
| 6 · The machines are real | 4 |
| 7 · **Drift** | 8 |
| 8 · Audit trail | 4 |
| 9 · Teardown | 2 |
| Questions | 5–10 |
| **Total** | **35–45** |

Sections 4 and 5 overlap with the installations running. If you are
short of time, cut section 2 — never section 7.
