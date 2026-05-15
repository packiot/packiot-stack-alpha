#!/bin/bash
# Runs once on first container boot (docker-entrypoint-initdb.d).
# Creates TimescaleDB and pg_cron extensions in the packiot database.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-SQL
    CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    GRANT USAGE ON SCHEMA cron TO "$POSTGRES_USER";
SQL
