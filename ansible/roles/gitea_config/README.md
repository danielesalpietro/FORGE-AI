# `gitea_config`

Creates the organisation, the GitOps repository and the push webhook in
Gitea, through the REST API v1.

## Two integration strategies

Selected by `gitops.sync_strategy`:

### `mirror` (default)

Gitea **pulls** from the GitHub upstream on a schedule
(`gitea_mirror_interval`, default 10m).

- GitHub holds **no credential for Gitea at all**. A compromised GitHub
  Actions runner cannot push to the GitOps repository.
- The Gitea repository is read-only, so its branch protection is moot —
  the review gate lives in GitHub.
- Propagation is delayed by up to the mirror interval.

### `push`

GitHub Actions pushes approved `main` commits into Gitea with a scoped
deploy token.

- Propagation is immediate.
- A Gitea credential now lives in GitHub secrets. That is the trade.

`docs/GITOPS-WORKFLOW.md` compares them properly.

## Webhook

Created with `branch_filter` set to the default branch and a shared
secret. Gitea signs the raw body with HMAC-SHA256 and sends the hex
digest in `X-Gitea-Signature`; `compose/webhook/app.py` verifies it
**before parsing anything**. The role refuses to proceed with a secret
shorter than 32 characters — without a strong one, anyone who can reach
the receiver can trigger an infrastructure deployment.

The secret must match `FORGE_WEBHOOK_SECRET` in `compose/.env`.
`bootstrap/create-secrets.sh` writes both from one generated value.

## Branch protection is printed, not attempted

Gitea's branch-protection payload has changed shape between releases,
and a silently-wrong API call leaves the branch **unprotected** — worse
than not trying. The role prints the exact UI steps and the URL instead
of guessing. This is the one place where "the API can do it" was not
true enough to rely on.

## Token scope

The role asserts a token is present and tells the operator to scope it
to `write:organization` and `write:repository` — not `sudo`/admin. See
`docs/SECURITY.md`, "Gitea token theft".

## Tags

`bootstrap`, `gitops`, `security`
