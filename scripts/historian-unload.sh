#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# historian-unload.sh — legacy PG12 `equipment_values` → Parquet → S3 historian
# ══════════════════════════════════════════════════════════════════════════════
#
# Codified, repeatable unload job for the AWS-native raw-history historian
# (Approach B3 in docs/plans/legacy-history-migration-costing.md, chosen to avoid
# GCP). Reads the legacy client DB (`packiot40`, PG12/TimescaleDB) SELECT-ONLY and
# writes ZSTD Parquet to the partitioned S3 layout that the Athena partition-
# projection table (terraform/production/historian.tf) reads.
#
# COST-OPTIMISED BY DESIGN — see docs/plans/historian-s3-athena-runbook.md:
#   * Unload compute = DuckDB on cheap/existing compute (≈$0). NO Glue ETL/Spark.
#   * Catalog        = Athena partition projection. NO Glue crawler ever runs.
#   * Storage        = S3 Parquet ($/mo trivial); Athena query = $5/TB scanned,
#                      kept tiny by Parquet columnar + partition pruning.
#
# SAFETY (hard rules):
#   * Legacy is SELECT-ONLY forever. The DB role (`awslambda`) has no write grant;
#     every read runs inside a server-side statement_timeout. We NEVER write to
#     legacy and NEVER touch the production operational DB.
#   * Timescale-aware: we stream via DuckDB `postgres_query()` so Postgres's own
#     planner (with the TimescaleDB chunk-exclusion hook) runs the scan. The plain
#     postgres_scanner ctid-parallel path does NOT traverse hypertable chunks and
#     hangs — do not "simplify" this to `SELECT ... FROM legacy.equipment_values`.
#   * Throttled: one calendar day per query (bounded rows + bounded chunk scan),
#     with an inter-day sleep, so the live client DB is never hammered.
#
# IDEMPOTENT: one Parquet object per (tenant, day) at a deterministic key
#   equipment_values/enterprise=<ent>/year=<Y>/month=<M>/data-<YYYY-MM-DD>.parquet
# Re-running a day overwrites exactly that object — safe to resume/retry.
#
# USAGE:
#   scripts/historian-unload.sh <id_enterprise> <start_date> <end_date_exclusive> [sleep_secs]
# EXAMPLE (the pilot — CPACK/ent-1, July 2026):
#   scripts/historian-unload.sh 1 2026-07-01 2026-08-01 1
#
# REQUIREMENTS: aws CLI (creds in the standard chain), jq, and the DuckDB CLI
# (auto-installed to ~/.duckdb if missing). Legacy creds come from the
# `databaseCredentials` secret (us-east-1), same path as the powerbi read script.
set -euo pipefail

ENT="${1:?id_enterprise required}"
START="${2:?start_date (YYYY-MM-DD) required}"
END="${3:?end_date_exclusive (YYYY-MM-DD) required}"
SLEEP_SECS="${4:-1}"

REGION="${AWS_REGION:-us-east-1}"
ACCT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${HISTORIAN_BUCKET:-packiot-production-historian-${ACCT}}"
DUCKDB="${DUCKDB:-$HOME/.duckdb/cli/latest/duckdb}"

if [ ! -x "$DUCKDB" ]; then
  echo "[historian] DuckDB CLI not found — installing to ~/.duckdb ..."
  curl -fsSL https://install.duckdb.org | bash
  DUCKDB="$HOME/.duckdb/cli/latest/duckdb"
fi

# ── Legacy DB creds (SELECT-only awslambda role) ─────────────────────────────
SECRET="$(aws secretsmanager get-secret-value --secret-id databaseCredentials \
  --region us-east-1 --query SecretString --output text)"
PGHOST="$(jq -r .DB_HOST <<<"$SECRET")"; PGPORT="$(jq -r .DB_PORT <<<"$SECRET")"
PGUSER="$(jq -r .DB_USER <<<"$SECRET")"; PGPASSWORD="$(jq -r .DB_PASSWORD <<<"$SECRET")"
PGDATABASE="$(jq -r .DB_NAME <<<"$SECRET")"
CONNSTR="host=${PGHOST} port=${PGPORT} user=${PGUSER} password=${PGPASSWORD} dbname=${PGDATABASE} connect_timeout=20"

echo "[historian] tenant=${ENT} window=[${START},${END}) bucket=${BUCKET}"

# ── Per-day loop ─────────────────────────────────────────────────────────────
d="$START"
while [ "$d" \< "$END" ]; do
  next="$(date -u -d "${d} +1 day" +%Y-%m-%d)"
  Y="$(date -u -d "$d" +%Y)"
  M="$(( 10#$(date -u -d "$d" +%m) ))"   # un-padded to match integer projection
  KEY="equipment_values/enterprise=${ENT}/year=${Y}/month=${M}/data-${d}.parquet"
  S3URI="s3://${BUCKET}/${KEY}"

  "$DUCKDB" :memory: <<SQL
INSTALL postgres; LOAD postgres;
INSTALL httpfs; LOAD httpfs;
CREATE SECRET s3hist (TYPE s3, PROVIDER credential_chain, REGION '${REGION}');
ATTACH '${CONNSTR}' AS legacy (TYPE postgres, READ_ONLY);
COPY (
  SELECT * FROM postgres_query('legacy',
    'SELECT * FROM equipment_values
      WHERE id_enterprise = ${ENT}
        AND ts_value >= ''${d} 00:00:00+00''
        AND ts_value <  ''${next} 00:00:00+00''')
) TO '${S3URI}' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 122880);
SQL

  echo "[historian] wrote ${S3URI}"
  d="$next"
  sleep "$SLEEP_SECS"
done

echo "[historian] done tenant=${ENT} [${START},${END})"
