#!/usr/bin/env bash
# ops-backup-retention.sh — retire the ad-hoc repair backups in the ops schema.
#
# Every data repair saves the rows it touches into ops._bkp_<what>_<YYYYMMDD>[_<suffix>] (or the
# repair's own work list into ops._fix_..._<YYYYMMDD>) so it can be undone. They are only useful
# while a mistake could still surface; after that they are dead weight in every dump and restore.
# Rule: a table whose name carries a date older than RETAIN_DAYS (default 30) is dropped.
# Tables WITHOUT a date are never dropped here — they are listed so someone decides (and renames
# them with a date, or drops them by hand).
#
# Usage:  ops-backup-retention.sh            # dry run: list what would be dropped / kept / undated
#         APPLY=1 ops-backup-retention.sh    # drop the expired ones, one transaction
# Before APPLY: make sure a nightly backup taken AFTER the repairs exists (restore drill:
# terraform/staging/scripts/restore-db.sh) and that the invariants for the repaired data are green
# (SELECT * FROM ops.data_invariant_latest WHERE NOT ok).
# Env: STACK_ENV (default: the stack checkout's .env) for POSTGRES_HOST/USER/PASSWORD/PORT.
set -euo pipefail
RETAIN_DAYS="${RETAIN_DAYS:-30}"; APPLY="${APPLY:-0}"
[[ "$RETAIN_DAYS" =~ ^[0-9]+$ ]] || { echo "RETAIN_DAYS must be an integer" >&2; exit 2; }
STACK_ENV="${STACK_ENV:-/opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha/.env}"
# Read ONLY the needed keys — never `source` a .env (values may hold shell metacharacters).
envval() { grep -E "^$1=" "$STACK_ENV" | tail -1 | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
POSTGRES_HOST="$(envval POSTGRES_HOST)"; POSTGRES_USER="$(envval POSTGRES_USER)"
POSTGRES_PASSWORD="$(envval POSTGRES_PASSWORD)"; POSTGRES_PORT="$(envval POSTGRES_PORT)"
psql_() { docker run --rm -i -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:16-alpine \
  psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "$POSTGRES_USER" -d packiot_analytics \
       -v ON_ERROR_STOP=1 -At -F'|' -f - ; }

# The date is the first 20YYMMDD token in the name (some names carry a suffix after it).
classify="
WITH t AS (
  SELECT c.relname, pg_total_relation_size(c.oid) AS bytes,
         to_date(substring(c.relname FROM '_(20[0-9]{6})(_|\$)'), 'YYYYMMDD') AS made
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'ops' AND c.relkind = 'r' AND c.relname ~ '^_(bkp|fix)_')
SELECT CASE WHEN made IS NULL THEN 'undated'
            WHEN made < current_date - $RETAIN_DAYS THEN 'expired' ELSE 'kept' END AS state,
       relname, coalesce(made::text, '-'), pg_size_pretty(bytes)
  FROM t ORDER BY 1, 2;"

echo "ops backup tables (retain ${RETAIN_DAYS} d; state|table|dated|size):"
printf '%s\n' "$classify" | psql_
[ "$APPLY" = 1 ] || { echo "dry run — re-run with APPLY=1 to drop the 'expired' rows above"; exit 0; }

printf '%s\n' "SET lock_timeout = '10s';
BEGIN;
DO \$\$ DECLARE r record; BEGIN
  FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'ops' AND c.relkind = 'r' AND c.relname ~ '^_(bkp|fix)_'
              AND to_date(substring(c.relname FROM '_(20[0-9]{6})(_|\$)'), 'YYYYMMDD') < current_date - $RETAIN_DAYS
  LOOP
    EXECUTE format('DROP TABLE ops.%I', r.relname);
    RAISE NOTICE 'dropped ops.%', r.relname;
  END LOOP;
END \$\$;
COMMIT;" | psql_
