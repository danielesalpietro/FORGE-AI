#!/bin/sh
# =====================================================================
# FORGE-AI :: PostgreSQL bootstrap
# =====================================================================
# Runs once, on an empty data directory, from the postgres image's
# docker-entrypoint-initdb.d hook. Creates one role and one database
# per application so that a compromise of the Semaphore credential does
# not hand over the Gitea data, and vice versa.
#
# Re-running is harmless: the entrypoint only executes this on first
# initialisation, and every statement is guarded anyway.
set -eu

echo "[forge-ai] provisioning application databases"

create_role_and_db() {
    role="$1"
    password="$2"
    dbname="$3"

    if [ -z "${password}" ]; then
        echo "[forge-ai] FATAL: no password supplied for role '${role}'" >&2
        exit 1
    fi

    psql --username "${POSTGRES_USER}" --dbname postgres --no-password \
         --set ON_ERROR_STOP=1 \
         --set role="${role}" --set password="${password}" --set dbname="${dbname}" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'role', :'password')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec

SELECT format('CREATE DATABASE %I OWNER %I ENCODING ''UTF8''', :'dbname', :'role')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'dbname')
\gexec

SELECT format('GRANT ALL PRIVILEGES ON DATABASE %I TO %I', :'dbname', :'role')
\gexec
SQL

    # Owning the public schema keeps the application from needing any
    # privilege on the other application's database.
    psql --username "${POSTGRES_USER}" --dbname "${dbname}" --no-password \
         --set ON_ERROR_STOP=1 --set role="${role}" <<'SQL'
SELECT format('ALTER SCHEMA public OWNER TO %I', :'role')
\gexec
REVOKE ALL ON SCHEMA public FROM PUBLIC;
SQL

    echo "[forge-ai]   role '${role}' and database '${dbname}' ready"
}

create_role_and_db "${GITEA_DB_USER:-gitea}"         "${GITEA_DB_PASSWORD:-}"     "${GITEA_DB_NAME:-gitea}"
create_role_and_db "${SEMAPHORE_DB_USER:-semaphore}" "${SEMAPHORE_DB_PASSWORD:-}" "${SEMAPHORE_DB_NAME:-semaphore}"

echo "[forge-ai] database bootstrap complete"
