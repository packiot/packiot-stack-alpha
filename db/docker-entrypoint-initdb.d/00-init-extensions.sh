#!/bin/bash
# First boot only (empty data directory). pg_cron is created in its home database `postgres`
# (cron.database_name=postgres, db_init.sh) and schedules elsewhere with cron.schedule_in_database.
# No TimescaleDB since ADR-0063's end state (2026-10-15).
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
    GRANT USAGE ON SCHEMA cron TO "$POSTGRES_USER";
SQL
