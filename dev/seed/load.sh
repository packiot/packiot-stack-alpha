#!/usr/bin/env bash
# load.sh — first-start loader inside the dev-seed image (ADR-0060 D6). Run by the Timescale image's
# /docker-entrypoint-initdb.d hook, once, as the postgres superuser.
#   1. roles from staging (no passwords) → every login role gets the dev password "dev" (local only)
#   2. full DDL restore of packiot_analytics between timescaledb_pre_restore()/post_restore()
#      (keeps hypertables, caggs and policies; a schema-only dump would turn them into plain tables)
#   3. load.sql with delta_days = whole weeks between snapshot_end and now (D6: weekday + shift calendars intact)
set -euo pipefail
SEED=/seed
DB=packiot_analytics
PSQL=(psql -X -q -v ON_ERROR_STOP=1 --username "$POSTGRES_USER")

grep -vE '^(CREATE|ALTER) ROLE postgres[ ;]' "$SEED/roles.sql" | "${PSQL[@]}" -d postgres -f -
"${PSQL[@]}" -d postgres -c "DO \$\$ DECLARE r record; BEGIN
  FOR r IN SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolname <> current_user LOOP
    EXECUTE format('ALTER ROLE %I PASSWORD %L', r.rolname, 'dev'); END LOOP; END \$\$;"

# the dev env sets POSTGRES_DB=packiot_analytics, so the image entrypoint may have created it (empty) already
if ! "${PSQL[@]}" -d postgres -At -c "SELECT 1 FROM pg_database WHERE datname = '$DB'" | grep -q 1; then
  createdb --username "$POSTGRES_USER" "$DB"
fi
# the source database's own settings (search_path!) — read-api's SQL uses unqualified names
[ ! -s "$SEED/db_settings.sql" ] || "${PSQL[@]}" -d postgres -f "$SEED/db_settings.sql" >/dev/null
"${PSQL[@]}" -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore();" >/dev/null
# pg_restore reports benign "already exists" for the extension; anything else fails the init
if ! pg_restore --username "$POSTGRES_USER" -d "$DB" "$SEED/schema.dump" 2> /tmp/restore.err; then
  if grep -E '^pg_restore: error:' /tmp/restore.err | grep -vqE 'extension "timescaledb" already exists|schema "public" already exists'; then
    grep -E '^pg_restore: error:' /tmp/restore.err | head -20; echo "devseed: pg_restore failed"; exit 1
  fi
fi
"${PSQL[@]}" -d "$DB" -c "SELECT timescaledb_post_restore();" >/dev/null
# post_restore restarts Timescale's job scheduler: pause every scheduled job until the data is in, or jobs run
# against a half-loaded DB (2026-10-07: the invariants job and a rollup errored mid-load). Resumed below.
PAUSED=$("${PSQL[@]}" -d "$DB" -At -c "SELECT coalesce(string_agg(job_id::text, ','), '') FROM timescaledb_information.jobs WHERE scheduled")
[ -z "$PAUSED" ] || "${PSQL[@]}" -d "$DB" -c "SELECT alter_job(j, scheduled => false) FROM unnest('{$PAUSED}'::int[]) j" >/dev/null

END=$(sed -n 's/.*"snapshot_end": *"\([^"]*\)".*/\1/p' "$SEED/metadata.json")
DELTA=$("${PSQL[@]}" -d "$DB" -At -c "SELECT (floor(extract(epoch FROM now() - '$END'::timestamptz) / 604800) * 7)::int")
echo "devseed: snapshot_end=$END → shifting all timestamps by $DELTA days"
"${PSQL[@]}" -d "$DB" -v delta_days="$DELTA" -f "$SEED/load.sql"
[ -z "$PAUSED" ] || "${PSQL[@]}" -d "$DB" -c "SELECT alter_job(j, scheduled => true) FROM unnest('{$PAUSED}'::int[]) j" >/dev/null
echo "devseed: $(echo "$PAUSED" | tr ',' '\n' | grep -c . ) scheduled job(s) paused during the load and resumed"
echo "devseed: loaded $(sed -n 's/.*"tenant": *\([0-9]*\).*/tenant \1/p' "$SEED/metadata.json") into $DB"
