# `drift_detection`

Answers "what on these machines no longer matches Git?" — using two
independent sources, because neither is sufficient alone.

## Why two sources

| Source | Coverage | Accuracy |
|---|---|---|
| Ansible check mode | Broad — everything the baseline roles manage | Depends on each module implementing check mode properly |
| Read-only compliance probes | Narrow — only what someone wrote a probe for | High: they read the live machine |

Check mode **over-reports on Linux** (cosmetic "would change" on tasks
that are effectively idempotent) and **under-reports on Windows**:
`win_shell` and `win_updates` have no check-mode support at all, and
`win_security_policy` only partial. A check-mode-only report would be
silently blind to SMBv1, the firewall defaults, the execution policy and
the event log sizing.

So the role also runs the probes in
`group_vars/{linux,windows}/main.yml` and **labels every finding with
its source**. It records the known blind spots in
`check_mode_unsupported` so the report states where it cannot see,
rather than implying full coverage.

This project does not claim that all Ansible modules have perfect check
mode support. `docs/OPERATIONS.md` sets out the limitations.

## Output

```text
/srv/forge-ai/reports/drift/
  drift-<deployment-id>.json     machine-readable
  drift-<deployment-id>.md       human-readable
  latest.json -> ...
  latest.md   -> ...
```

## Reconciliation is a separate, manual step

Detection never fixes anything. `drift.auto_reconcile` is `false` by
default and scheduled reconciliation is opt-in. When drift is found, the
report says:

> If a deviation is legitimate, change the desired state in Git and open
> a pull request — do not reconcile it away.

That is the GitOps position: the repository is the source of truth, so a
change that *should* persist belongs in the repository.

## Failing on drift

`drift_fail_on_drift` is `false` by default so an operator running
`make drift` gets a report rather than a stack trace. Set it `true` on a
**scheduled Semaphore drift check** so the task goes red and the
notification fires.

## Tags

`drift`, `validation`, `linux`, `windows`, `reporting`
