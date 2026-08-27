# Semaphore setup

What `ansible/roles/semaphore_config` creates, what it deliberately does
not, and how to do the rest.

---

## Automatic

`make bootstrap` runs the role, which uses the Semaphore REST API to
create:

| Object | Detail |
|---|---|
| Project | `gitops.semaphore_project_name`, `max_parallel_tasks: 1` |
| Key store | `forge-ai-ssh`, `forge-ai-windows`, `forge-ai-vault` |
| Repository | `gitea-gitops`, cloned from `http://gitea:3000/...` |
| Inventory | `poc`, pointing at the dynamic inventory *inside* the clone |
| Environment | `poc`, non-sensitive run defaults |
| Templates | All thirteen |

### The API token

Semaphore issues tokens per user. `bootstrap.sh` does this and stores
the result in the vault:

```bash
curl -sS -X POST http://127.0.0.1:3001/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"auth":"forgeadmin","password":"..."}' -c /tmp/sem.jar

curl -sS -X POST http://127.0.0.1:3001/api/user/tokens -b /tmp/sem.jar | jq -r .id
```

The password goes in a request **body**, never on a command line where
it would be visible in the process table.

---

## The thirteen templates

| # | Name | Playbook | Notes |
|---|---|---|---|
| 01 | Validate prerequisites | `validate-prerequisites.yml` | Read-only |
| 02 | Deploy provisioning services | `deploy-pxe-stack.yml` | |
| 03 | Prepare Ubuntu media | `prepare-ubuntu-media.yml` | |
| 04 | Prepare Windows media | `prepare-windows-media.yml` | Ends cleanly with no media |
| 05 | Create target VMs | `create-vms.yml` | |
| 06 | Provision Ubuntu | `provision-ubuntu.yml` | |
| 07 | Provision Windows | `provision-windows.yml` | Requires media |
| 08 | Configure Ubuntu | `configure-targets.yml --limit linux` | |
| 09 | Configure Windows | `configure-targets.yml --limit windows` | |
| 10 | Validate deployment | `validate-deployment.yml` | Includes the idempotence check |
| 11 | Detect drift | `detect-drift.yml` | Changes nothing |
| 12 | Reconcile drift | `reconcile.yml` | Review the report first |
| **99** | **DESTROY the PoC** | `destroy-poc.yml` | **Destructive** |

They are numbered so the deployment order is the display order, and so
the destructive one sorts last rather than sitting next to `12`.

### Why 99 is separated the way it is

1. It is numbered to sort last.
2. It has a **required** survey variable, `confirm_destroy`, whose title
   tells the operator exactly what to type.
3. `destroy-poc.yml` asserts the same token independently.

Point 3 is the one that matters. A survey variable is a usability
control; anyone calling `POST /api/project/N/tasks` directly bypasses
it. The Ansible-side assertion does not care how the task was started.

---

## Where secrets live, and why

| Store | Holds | Because |
|---|---|---|
| **Semaphore Key Store** | Secrets used by tasks Semaphore runs | Encrypted at rest with `SEMAPHORE_ACCESS_KEY_ENCRYPTION`; a runner has no vault password, and giving it one would defeat the point of having a vault |
| **Ansible Vault** | The same secrets, for operator-run tasks | The operator has the password |
| **Semaphore *environment*** | **Nothing sensitive** | Semaphore stores it as **plain JSON in its database** |

That last row is worth being explicit about. The environment is a
convenient place to put variables and an actively bad place to put
credentials. `ansible/templates/semaphore/environment.json.j2` says so
in its own `_comment` block, and carries only run defaults:

```json
{
  "forge_trigger": "semaphore",
  "forge_boot_base_url": "http://192.168.250.1:8080",
  "prereq_report_only": false,
  "ipxe_reset_state": false,
  "vm_lifecycle_recreate_disk": false,
  "drift_fail_on_drift": false,
  "confirm_destroy": ""
}
```

### `SEMAPHORE_ACCESS_KEY_ENCRYPTION`

Exactly **32 raw bytes, base64-encoded**. A different length is rejected
at start-up with an error that does not say so — Semaphore simply
restarts in a loop.

```bash
head -c 32 /dev/urandom | base64 -w0
```

**Regenerating it makes every key already in the Key Store permanently
undecryptable.** `create-secrets.sh --force` warns and asks before doing
it.

---

## What is left manual

The role **prints** these rather than implying it did them.

### Branch protection in Gitea

Gitea's branch-protection API payload has changed shape between
releases, and a silently-wrong call leaves the branch **unprotected** —
worse than not trying. The role prints the URL and the exact settings.

With the default `mirror` strategy this is largely moot: the Gitea
repository is read-only and the review gate is in GitHub.

### Schedules

**Project → Schedules → New.**

A drift check every six hours:

| Field | Value |
|---|---|
| Name | `Drift check` |
| Cron | `0 */6 * * *` |
| Template | `11 Detect drift` |

To make it **alert**, set `drift_fail_on_drift: true` in the template's
environment. The task then goes red when drift is found and the
notification fires. Left `false`, an operator running it by hand gets a
report rather than a stack trace — which is the right default for
interactive use and the wrong one for a schedule.

**Do not schedule template 12.** `drift.auto_reconcile` is `false` for a
reason: automatic reconciliation erases the evidence of what changed.

### Notifications

**Project → Settings → Alerts.** Slack, Telegram or email. Worth
enabling for the drift schedule and for template 99.

---

## Running a template

**Project → Task Templates → Run.**

Or over the API, which is what the webhook receiver does:

```bash
curl -X POST http://127.0.0.1:3001/api/project/1/tasks \
  -H "Authorization: Bearer ${SEMAPHORE_API_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d '{
        "template_id": 10,
        "debug": false,
        "dry_run": false,
        "message": "triggered by hand",
        "environment": "{\"forge_trigger\":\"api\"}"
      }'
```

`dry_run: true` maps to `--check`, which is how a drift-style run works
from the UI.

---

## Wiring the webhook

After the templates exist, the role prints:

```text
FORGE_TEMPLATE_ROUTES=[["docs/**",null],["*.md",null],["**",10]]
SEMAPHORE_PROJECT_ID=1
```

Put both in `compose/.env` and restart the receiver:

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml restart webhook
```

The catch-all deliberately points at the **validation** template rather
than a full reprovision. A push should not rebuild two virtual machines
without someone choosing to.

---

## Troubleshooting

### Semaphore restarts in a loop

```bash
docker compose logs semaphore | tail -30
```

Almost always `SEMAPHORE_ACCESS_KEY_ENCRYPTION` not being exactly 32
raw bytes base64-encoded.

### It cannot clone the repository

```bash
docker compose exec semaphore sh -c \
  'git ls-remote http://gitea:3000/forge-ai/gitops-infrastructure.git'
```

Semaphore reaches Gitea over the **Docker network** —
`http://gitea:3000/...`, not the proxied hostname. If the mirror has not
synced yet, force it in the Gitea UI under Settings → Mirror.

### A task fails with "no such file or directory"

The playbook path is relative to the repository root **inside the
clone**: `ansible/playbooks/site.yml`, not `playbooks/site.yml`.

### A task cannot decrypt the vault

The `forge-ai-vault` key store entry holds the vault password. Confirm
it exists and that the template's environment references it. Alternatively,
move the value into the Key Store as its own entry and stop using the
vault for Semaphore-run tasks entirely — which is the cleaner
arrangement if every run comes through Semaphore.

### The webhook triggers nothing

```bash
docker compose logs webhook | tail
```

| Message | Cause |
|---|---|
| `bad or missing HMAC signature` | The secret differs between Gitea and `compose/.env` |
| `branch 'x' is not the deployment branch` | Working as intended |
| `all N changed path(s) matched 'docs/**'` | Working as intended |
| `SEMAPHORE_API_TOKEN or SEMAPHORE_PROJECT_ID is not configured` | Add the lines the role printed |
