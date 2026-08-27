# `semaphore_config`

Creates the Semaphore project, key store entries, repository, inventory,
environment and the thirteen workflow templates — through the REST API.

## Workflow stages

| # | Template | Playbook |
|---|---|---|
| 01 | Validate prerequisites | `validate-prerequisites.yml` |
| 02 | Deploy provisioning services | `deploy-pxe-stack.yml` |
| 03 | Prepare Ubuntu media | `prepare-ubuntu-media.yml` |
| 04 | Prepare Windows media | `prepare-windows-media.yml` |
| 05 | Create target VMs | `create-vms.yml` |
| 06 | Provision Ubuntu | `provision-ubuntu.yml` |
| 07 | Provision Windows | `provision-windows.yml` |
| 08 | Configure Ubuntu | `configure-targets.yml --limit linux` |
| 09 | Configure Windows | `configure-targets.yml --limit windows` |
| 10 | Validate deployment | `validate-deployment.yml` |
| 11 | Detect drift | `detect-drift.yml` |
| 12 | Reconcile drift | `reconcile.yml` |
| **99** | **DESTROY the PoC** | `destroy-poc.yml` |

## The destructive template is separated deliberately

Template 99 is numbered to sort last, is created with a **required
survey variable** `confirm_destroy`, and its title tells the operator
exactly what to type.

The UI control is not the security boundary. `destroy-poc.yml`
independently asserts `confirm_destroy == safety.destroy_confirmation_token`
before touching anything, because a survey variable can be bypassed by
anyone calling the API directly.

## Where secrets live, and why

| Store | Holds | Because |
|---|---|---|
| Semaphore Key Store | Secrets used by tasks Semaphore runs | Encrypted at rest with `SEMAPHORE_ACCESS_KEY_ENCRYPTION`; a runner has no vault password |
| Ansible Vault | Secrets used by tasks an operator runs | The operator has the vault password |
| GitHub Actions secrets | Only the Gitea sync credential | Nothing else needs to leave GitHub |

The Semaphore **environment** is *not* a secret store: Semaphore keeps
it as plain JSON in its database. `environment.json.j2` says so in its
own `_comment` and carries only non-sensitive run defaults.

## Webhook routing

After creating the templates the role prints the exact
`FORGE_TEMPLATE_ROUTES` and `SEMAPHORE_PROJECT_ID` lines for
`compose/.env`. The default routes a docs-only commit to *nothing* and
everything else to the **validation** template — not to a full
reprovision. A push should not rebuild two virtual machines without
someone choosing to.

## What is left manual

- **Schedules.** Add a drift-check schedule in Project → Schedules if
  you want one; `drift.auto_reconcile` stays opt-in.
- The role prints what remains rather than implying it did everything.

## Tags

`bootstrap`, `gitops`, `security`
