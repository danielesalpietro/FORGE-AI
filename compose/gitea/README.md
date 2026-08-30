# `compose/gitea/`

Gitea is configured **entirely through environment variables** in
`compose/docker-compose.yml`, using Gitea's own
`GITEA__section__KEY` convention:

```yaml
GITEA__server__ROOT_URL:            https://gitea.poc.local:8443/
GITEA__security__INSTALL_LOCK:      "true"
GITEA__service__DISABLE_REGISTRATION: "true"
GITEA__mirror__ENABLED:             "true"
```

There is no `app.ini` in this repository, and that is deliberate. Gitea
writes its own `app.ini` into the `gitea-config` volume on first start
and keeps it there; a file mounted over it would fight with Gitea's own
migrations on every upgrade. Environment variables are the supported way
to configure it declaratively.

Note the `cron_2E_update_mirrors` key in the compose file: `_2E_` is
Gitea's escaping for a literal dot in a section name
(`cron.update_mirrors`).

## What lives where

| | |
|---|---|
| Configuration | `compose/docker-compose.yml`, environment variables |
| Generated `app.ini` | The `gitea-config` Docker volume |
| Repositories and database | The `gitea-data` volume and PostgreSQL |
| Organisation, repository, webhook | Created by `ansible/roles/gitea_config` through the REST API |

## Inspecting the running configuration

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml \
  exec gitea cat /etc/gitea/app.ini
```

## Changing something

Add or edit the `GITEA__*` variable in `docker-compose.yml`, then:

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml up -d gitea
```

Gitea reapplies environment variables to `app.ini` on every start, so
the change takes effect without touching the volume.

See `docs/GITOPS-WORKFLOW.md` for the repository, webhook and mirror
setup, and `ansible/roles/gitea_config/README.md` for what the role
automates and what it deliberately leaves manual.
