# `compose/database/`

PostgreSQL 16, with **one role and one database per application**.

## `init/01-create-databases.sh`

Runs once, from the postgres image's `docker-entrypoint-initdb.d` hook,
on an **empty data directory only**. It creates:

| Role | Database | Owns |
|---|---|---|
| `gitea` | `gitea` | Its own `public` schema |
| `semaphore` | `semaphore` | Its own `public` schema |

Separate roles so that a compromise of the Semaphore credential does not
hand over the Gitea data, and vice versa. Each role owns its own
`public` schema and `PUBLIC` is revoked from it, so neither can reach
into the other's database.

Every statement is guarded with `WHERE NOT EXISTS`, so the script is
re-runnable even though the entrypoint only calls it once. The
entrypoint's behaviour is the reason it is *only* called once — and the
reason a change here does not take effect on an existing deployment:

```bash
# Only if you are prepared to lose everything in it
docker compose down -v database
docker compose up -d database
```

## Backup

There is **no backup automation**, which `docs/LIMITATIONS.md` records
as a limitation rather than leaving to be discovered.

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml \
  exec database pg_dumpall -U forgepg > forge-db-$(date +%F).sql
```

Restore into an empty instance:

```bash
docker compose exec -T database psql -U forgepg < forge-db-2026-01-01.sql
```

## Connecting

```bash
docker compose --env-file compose/.env -f compose/docker-compose.yml \
  exec database psql -U forgepg -d gitea
```

The port is **not published**. The database is reachable only from the
`forge-backend` Docker network.
