# `reporting`

Writes the deployment record: JSON for automation, Markdown for humans,
HTML for sharing.

## It reads facts, it does not re-measure

Every role that did work published a **cacheable fact**
(`forge_ubuntu_media`, `forge_windows_media`, `forge_component_versions`,
`forge_prereq_result`, `forge_windows_validation`, …). This role only
assembles them.

That is deliberate: a report that had to re-measure the system could not
describe a run that **partially failed** — and a partially failed run is
exactly when the report matters most.

## What is in it

Deployment ID · git commit and branch · start/end/duration · operator ·
trigger · per-host OS, addressing, resources, provisioning /
configuration / validation results · **boot state and install attempt
count** · failed tasks · collected facts · source media with SHA-256 ·
component versions · log locations · link to the Semaphore task.

The install attempt count comes straight from the state service, so the
report shows when a host needed two attempts — the sort of thing that is
invisible in a "green" pipeline and matters at a demo.

## Semaphore linkage

`SEMAPHORE_URL`, `SEMAPHORE_TASK_ID` and `SEMAPHORE_PROJECT_ID` are read
from the environment. When the run came from Semaphore the report links
back to the task log; when it came from a CLI they are empty and the
link is omitted rather than rendered broken.

## Output

```text
/srv/forge-ai/reports/
  deployment-<id>.json
  deployment-<id>.md
  deployment-<id>.html
  latest.json -> ...
  latest.md   -> ...
  latest.html -> ...
```

Retention is `reporting.retain` (default 30).

## Log locations it records

dnsmasq · boot server nginx access log · state service · guest installer
uploads · `/var/log/installer` on the Ubuntu target ·
`C:\Windows\Panther` and `C:\ProgramData\forge-ai` on the Windows target
· Ansible · Semaphore · `/var/log/libvirt/qemu/<domain>.log` — each with
a one-line hint about what it is actually good for.

## Tags

`reporting`, `validation`
