#!/bin/bash
# Creates the `authentik` role + database on first postgres container boot.
# Runs once via /docker-entrypoint-initdb.d/ — postgres image convention.
#
# Why this exists: compose.production.yml's authentik-server connects to a
# separate `authentik` DB owned by an `authentik` role (per Authentik's
# operational best practice — don't mix Authentik's schema with the main
# application DB). Without this init, authentik-server crashes at first
# boot with FATAL: role "authentik" does not exist.
#
# Staging's analogue: the DB EC2's db_init.sh creates the same role + DB
# manually via psql. Production runs a single EC2 + local postgres
# container, so the init is delegated to docker-entrypoint-initdb.d/
# instead (postgres image runs every .sh / .sql in this directory on first
# boot of an empty data volume).
#
# Idempotent: skipped if the data volume already has tables (postgres image
# only runs initdb scripts when PGDATA is empty). Re-runs require destroying
# the pg-data volume.
#
# Requires the AUTHENTIK_DB_PASSWORD env var to be set on the postgres
# container — see compose.production.yml.

set -euo pipefail

if [ -z "${AUTHENTIK_DB_PASSWORD:-}" ]; then
    echo "[authentik-db-init] WARNING: AUTHENTIK_DB_PASSWORD not set — skipping"
    echo "[authentik-db-init]   authentik-server WILL fail to start. Set the env var on the postgres service."
    exit 0
fi

echo "[authentik-db-init] Creating authentik role + database..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    -- Role: only used by Authentik to log into its own database.
    -- LOGIN privilege; no CREATEDB / SUPERUSER / REPLICATION.
    -- pgcrypto is needed by Authentik's password hashing in the same DB.
    CREATE ROLE authentik WITH LOGIN PASSWORD '$AUTHENTIK_DB_PASSWORD';

    -- Database owned by the authentik role so Authentik can manage its own
    -- schema (run migrations, create tables, etc.) without superuser perms.
    CREATE DATABASE authentik WITH OWNER = authentik;

    -- Authentik uses pgcrypto for password hashing inside its DB.
    -- Connect into the new DB to create the extension there.
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "authentik" <<-SQL
    CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL

echo "[authentik-db-init] authentik role + database created; pgcrypto enabled in authentik DB"
