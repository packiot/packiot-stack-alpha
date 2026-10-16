#!/usr/bin/env bash
# historian-cold-export.sh — ADR-0065 P1: archive CLOSED tenant-days of the analytics hot tables to Parquet
# (s3://<historian bucket>/silver/<table>/enterprise=E/year=Y/month=M/day=D/f3.parquet) and record each file in the
# ops.cold_export manifest. A row is marked VERIFIED only after the written file was read back and its row count +
# Σ measures matched the hot slice — that, and only that, opens ops.partition_maintain()'s drop gate (ADR-0065 P0).
#
# Idempotent and self-healing: the work list is every closed tenant-day whose hot slice (rows, Σ) differs from its
# verified manifest row (or has none). A late correction to an exported day (backfill, edge repair, re-derived events)
# changes the slice → the day is exported again and the manifest row replaced.
#
#   closed day   : its end is ≥ COLD_EXPORT_CLOSE_HOURS (48) in the past — the engine's late-data window
#   tenants      : all with rows, minus ops.cold_export_exempt (the sandbox twin)
#   relations    : silver.equipment_values (Σ net/gross increments), silver.equipment_events (Σ duration)
#
# Env (defaults for the staging app box): HISTORIAN_BUCKET, COLD_EXPORT_ROOT (s3://bucket or a local dir for tests),
# COLD_EXPORT_CLOSE_HOURS, COLD_EXPORT_MAX_DAYS (cap per relation per run; 0 = all), COLD_EXPORT_RELATIONS (subset),
# AN_HOST/AN_USER/ANALYTICS_DB_PASSWORD (default from /opt/packiot/.env), PSQL_CMD (psql invocation, tests), DUCKDB.
set -euo pipefail
export HOME="${HOME:-/root}"
log() { echo "[cold-export $(date -u +%FT%TZ)] $*"; }

ENVFILE="${ENVFILE:-/opt/packiot/.env}"
envget() { [ -f "$ENVFILE" ] && grep -m1 "^$1=" "$ENVFILE" | cut -d= -f2- | tr -d "\"'" || true; }
AN_HOST="${AN_HOST:-$(envget POSTGRES_HOST_UPSTREAM)}"
AN_PORT="${AN_PORT:-5432}"
AN_USER="${AN_USER:-$(envget POSTGRES_USER)}"; AN_USER="${AN_USER:-postgres}"
AN_DB="${AN_DB:-packiot_analytics}"
APW="${ANALYTICS_DB_PASSWORD:-$(envget POSTGRES_PASSWORD)}"
BUCKET="${HISTORIAN_BUCKET:-packiot-staging-historian-639178078294}"
ROOT="${COLD_EXPORT_ROOT:-s3://${BUCKET}}"
CLOSE_HOURS="${COLD_EXPORT_CLOSE_HOURS:-48}"
MAX_DAYS="${COLD_EXPORT_MAX_DAYS:-0}"
RELATIONS="${COLD_EXPORT_RELATIONS:-silver.equipment_values silver.equipment_events}"
WORK="${COLD_EXPORT_TMP:-/var/tmp/historian-cold-export}"
mkdir -p "$WORK"
DUCKDB="${DUCKDB:-}"
if [ -z "$DUCKDB" ]; then
  for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" /root/.duckdb/cli/latest/duckdb "$(command -v duckdb || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && DUCKDB="$c" && break
  done
fi
[ -n "$DUCKDB" ] || { log "duckdb not found"; exit 3; }
[ -n "$AN_HOST" ] && [ -n "$APW" ] || { log "analytics host/password missing (POSTGRES_HOST_UPSTREAM / POSTGRES_PASSWORD)"; exit 2; }
PSQL_CMD="${PSQL_CMD:-docker run --rm -i --network host -e PGPASSWORD=$APW postgres:16-alpine psql -h $AN_HOST -p $AN_PORT -U $AN_USER -d $AN_DB}"
psqlq() { $PSQL_CMD -X -At -F'|' -v ON_ERROR_STOP=1 "$@"; }

# relation → time column, Σ measure expressions (NULL when absent), path under ROOT
spec() {
  case "$1" in
    silver.equipment_values) echo "ts_value|net_production_incr|gross_production_incr|silver/equipment_values" ;;
    silver.equipment_events) echo "ts_event|duration|NULL|silver/equipment_events" ;;
    *) return 1 ;;
  esac
}

total_ok=0; total_bad=0
for REL in $RELATIONS; do
  IFS='|' read -r TCOL NET GROSS PATH_ <<<"$(spec "$REL")" || { log "unknown relation $REL"; exit 2; }
  LIMIT=""; [ "$MAX_DAYS" -gt 0 ] && LIMIT="LIMIT $MAX_DAYS"
  # work list: closed tenant-days whose hot slice differs from a verified manifest row (or has none)
  psqlq > "$WORK/work.tsv" <<SQL
WITH hot AS (
  SELECT id_enterprise AS e, ($TCOL AT TIME ZONE 'UTC')::date AS d, count(*) AS n,
         coalesce(sum(($NET)::float8), 0) AS s_net, coalesce(sum(($GROSS)::float8), 0) AS s_gross
    FROM $REL
   WHERE $TCOL < date_trunc('day', now() - interval '$CLOSE_HOURS hours') AND id_enterprise IS NOT NULL
     AND id_enterprise NOT IN (SELECT id_enterprise FROM ops.cold_export_exempt)
   GROUP BY 1, 2)
SELECT h.e, h.d, h.n, h.s_net, h.s_gross FROM hot h
  LEFT JOIN ops.cold_export c ON c.relation = '$REL' AND c.id_enterprise = h.e
       AND c.period_lo = (h.d::timestamp AT TIME ZONE 'UTC') AND c.verified_at IS NOT NULL
 WHERE c.relation IS NULL OR c.rows <> h.n
    OR abs(coalesce(c.sum_net, 0) - h.s_net) > 1e-6 * greatest(1, abs(h.s_net))
    OR abs(coalesce(c.sum_gross, 0) - h.s_gross) > 1e-6 * greatest(1, abs(h.s_gross))
 ORDER BY h.d, h.e $LIMIT;
SQL
  N=$(grep -c . "$WORK/work.tsv" || true)
  log "$REL: $N tenant-day(s) to export"
  [ "$N" -gt 0 ] || continue

  # one DuckDB session per relation: export each tenant-day, read it back, compare with the hot slice
  {
    echo "SET memory_limit='${DUCKDB_MEMORY_LIMIT:-1200MB}'; SET threads=${DUCKDB_THREADS:-2}; SET preserve_insertion_order=false;"
    echo "SET temp_directory='$WORK';"
    case "$ROOT" in s3://*) echo "INSTALL httpfs; LOAD httpfs; CREATE SECRET s3sec (TYPE S3, PROVIDER credential_chain, REGION 'us-east-1');" ;; esac
    echo "INSTALL postgres; LOAD postgres;"
    echo "ATTACH 'host=$AN_HOST port=$AN_PORT dbname=$AN_DB user=$AN_USER password=$APW' AS an (TYPE postgres, READ_ONLY);"
    echo "CREATE TEMP TABLE res (e INTEGER, d DATE, uri VARCHAR, f_n BIGINT, f_net DOUBLE, f_gross DOUBLE, h_n BIGINT, h_net DOUBLE, h_gross DOUBLE);"
    while IFS='|' read -r E D _ _ _; do
      [ -n "$E" ] || continue
      Y=${D:0:4}; M=$((10#${D:5:2})); DD=$((10#${D:8:2}))
      DIR="$ROOT/$PATH_/enterprise=$E/year=$Y/month=$M/day=$DD"
      URI="$DIR/f3.parquet"
      case "$ROOT" in s3://*) ;; *) mkdir -p "$DIR" ;; esac
      Q="SELECT * FROM $REL WHERE id_enterprise = $E AND $TCOL >= ('$D'::date::timestamp AT TIME ZONE 'UTC') AND $TCOL < (('$D'::date + 1)::timestamp AT TIME ZONE 'UTC')"
      H="SELECT count(*) AS n, coalesce(sum(($NET)::float8), 0) AS s_net, coalesce(sum(($GROSS)::float8), 0) AS s_gross FROM $REL WHERE id_enterprise = $E AND $TCOL >= ('$D'::date::timestamp AT TIME ZONE 'UTC') AND $TCOL < (('$D'::date + 1)::timestamp AT TIME ZONE 'UTC')"
      FN="$NET"; FG="$GROSS"
      echo "COPY (SELECT * FROM postgres_query('an', \$q\$$Q\$q\$)) TO '$URI' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 100000, OVERWRITE_OR_IGNORE);"
      echo "INSERT INTO res SELECT $E, DATE '$D', '$URI', f.n, f.s_net, f.s_gross, h.n, h.s_net, h.s_gross
              FROM (SELECT count(*) AS n, coalesce(sum(CAST($FN AS DOUBLE)), 0) AS s_net, coalesce(sum(CAST($FG AS DOUBLE)), 0) AS s_gross FROM read_parquet('$URI')) f,
                   (SELECT * FROM postgres_query('an', \$q\$$H\$q\$)) h;"
    done < "$WORK/work.tsv"
    echo "COPY res TO '$WORK/res.csv' (HEADER false);"
  } > "$WORK/export.sql"
  "$DUCKDB" < "$WORK/export.sql" > "$WORK/duckdb.log" 2>&1 || { log "duckdb failed (see $WORK/duckdb.log)"; sed -E 's/password=[^ ]+/password=***/' "$WORK/duckdb.log" | tail -5; exit 1; }

  # manifest upsert: verified only when the file matches the hot slice exactly (rows) and within 1e-6 (Σ)
  {
    echo "CREATE TEMP TABLE res (e int, d date, uri text, f_n bigint, f_net float8, f_gross float8, h_n bigint, h_net float8, h_gross float8);"
    echo "COPY res FROM STDIN WITH (FORMAT csv);"
    cat "$WORK/res.csv"
    echo '\.'
    cat <<SQL
WITH up AS (
  INSERT INTO ops.cold_export (relation, id_enterprise, period_lo, period_hi, uri, rows, sum_net, sum_gross, exported_at, verified_at)
  SELECT '$REL', e, (d::timestamp AT TIME ZONE 'UTC'), ((d + 1)::timestamp AT TIME ZONE 'UTC'), uri, f_n, f_net, f_gross, now(),
         CASE WHEN f_n = h_n AND abs(f_net - h_net) <= 1e-6 * greatest(1, abs(h_net))
                   AND abs(f_gross - h_gross) <= 1e-6 * greatest(1, abs(h_gross)) THEN now() END
    FROM res
  ON CONFLICT (relation, id_enterprise, period_lo) DO UPDATE
     SET period_hi = EXCLUDED.period_hi, uri = EXCLUDED.uri, rows = EXCLUDED.rows, sum_net = EXCLUDED.sum_net,
         sum_gross = EXCLUDED.sum_gross, exported_at = EXCLUDED.exported_at, verified_at = EXCLUDED.verified_at
  RETURNING verified_at IS NOT NULL AS ok, id_enterprise, period_lo)
SELECT count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok),
       coalesce(string_agg(id_enterprise || ':' || period_lo::date, ' ') FILTER (WHERE NOT ok), '') FROM up;
SQL
  } > "$WORK/manifest.sql"
  IFS='|' read -r OK BAD BADLIST <<<"$(psqlq < "$WORK/manifest.sql" | tail -1)"
  log "$REL: verified $OK, mismatched $BAD ${BADLIST:+(re-export next run: $BADLIST)}"
  total_ok=$((total_ok + OK)); total_bad=$((total_bad + BAD))
  rm -f "$WORK/res.csv" "$WORK/export.sql"
done
log "done: verified $total_ok tenant-day file(s), $total_bad mismatched"
[ "$total_bad" -eq 0 ]
