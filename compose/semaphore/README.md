# `compose/semaphore/`

Semaphore is configured through environment variables in
`compose/docker-compose.yml`; everything beyond that — the project, key
store, repository, inventory, environment and all thirteen task
templates — is created through the REST API by
`ansible/roles/semaphore_config`.

There is no `config.json` in this repository. Semaphore writes its own
into the `semaphore-config` volume on first start, and a mounted file
would be overwritten by its migrations.

## Two variables worth knowing about

### `SEMAPHORE_ACCESS_KEY_ENCRYPTION`

Exactly **32 raw bytes, base64-encoded**. Any other length makes
Semaphore restart in a loop with an error that does not say so.

```bash
head -c 32 /dev/urandom | base64 -w0
```

**Regenerating it makes every key already in the Key Store permanently
undecryptable.** `bootstrap/create-secrets.sh --force` warns and asks
before doing it.

### `SEMAPHORE_ADMIN_PASSWORD`

Used only to create the initial administrator. Changing it later in
`.env` does not change the account — do that in the UI.

## What lives where

| | |
|---|---|
| Container configuration | `compose/docker-compose.yml` |
| Generated `config.json` | The `semaphore-config` volume |
| Task history, key store | The `semaphore-data` volume and PostgreSQL |
| Project, templates, keys | Created by `ansible/roles/semaphore_config` |
| Environment definition | Rendered from `ansible/templates/semaphore/environment.json.j2` |

## The environment is not a secret store

Semaphore keeps the project **environment** as plain JSON in its
database, unlike the Key Store which is encrypted at rest with
`SEMAPHORE_ACCESS_KEY_ENCRYPTION`.

`environment.json.j2` says so in its own `_comment` block and carries
only non-sensitive run defaults. Credentials go in the Key Store.

## Volumes

| Volume | Contents | Lost on `--volumes` |
|---|---|---|
| `semaphore-data` | Task history — the audit trail | yes |
| `semaphore-config` | Generated `config.json` | yes |
| `semaphore-tmp` | Repository clones and run scratch | yes, harmlessly |

`make destroy-all` keeps volumes unless `--volumes` is passed
explicitly, because the task history is the audit trail.

See `docs/SEMAPHORE-SETUP.md`.
