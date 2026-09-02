#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# historian-append.sh — ONGOING incremental append: new-prod F3 → Parquet → S3
# ══════════════════════════════════════════════════════════════════════════════
#
# WHAT THIS IS (and how it differs from the backfill)
# `historian-unload.sh` is the ONE-SHOT backfill: it drained the *legacy* PG12
# client DB (`packiot40`, SELECT-only) into the S3 cold store. THIS script is the
# ONGOING half of the same historian: a scheduled micro-batch that appends the
# LAST FEW DAYS of the *new-stack* live DB (new-prod F3 `equipment_values`) into
# the SAME partitioned Parquet layout, so the historian stays near-current without
# ever touching the operational DB on read.
#
#   backfill (historian-unload.sh)     append (this script)
#   ───────────────────────────────    ────────────────────────────────
#   source: legacy packiot40 (PG12)    source: new-prod F3 (r7g @ POSTGRES_HOST_UPSTREAM)
#   creds:  databaseCredentials secret creds:  /opt/packiot/.env (POSTGRES_* on the box)
#   window: full history, one-time     window: yesterday + N-day overlap, every day
#   schema: SELECT * (legacy shape)    schema: EXPLICIT 56-col projection → Glue shape
#   run:    manual, resumable          run:    systemd timer (historian-append.timer)
#
# When legacy retires, the historian = (legacy backfill) ∪ (new-prod appends). The
# two write DISJOINT partitions (legacy CPACK = enterprise=1; new-prod CPACK =
# enterprise=3), so they never collide inside a partition.
#
# ── THE SHARED MECHANISM (identical to the backfill — do NOT "simplify") ──────
#   * DuckDB `postgres_query('src', 'SELECT ...')` streams via Postgres's OWN
#     planner (TimescaleDB chunk-exclusion hook runs the scan). The plain
#     postgres_scanner ctid path scans the empty hypertable PARENT and HANGS.
#   * READ_ONLY attach + one calendar day per query (bounded rows/chunks). This is
#     a read-mostly job: it reads F3 and writes ONLY to S3 — never to any DB.
#
# ── WHY AN EXPLICIT PROJECTION (not SELECT *) ─────────────────────────────────
# F3 `equipment_values` has DIVERGED from the legacy shape the Athena/Glue table
# (terraform/production/historian.tf) was cut from:
#   * F3 adds trailing cols `ingested_at`, `source_seq` (NOT in the Glue table).
#   * `id_order_quality` is varchar(255) in F3 but smallint in Glue.
#   * `ts_value_production_quality` is date in F3 but smallint in Glue.
# A blind SELECT * would write Parquet whose per-column TYPES disagree with the
# other partitions in the same Athena table → inconsistent reads. So we project
# the EXACT 56 Glue columns, in order, casting each to the Glue type (TRY_CAST so
# one odd value can't fail a whole day). Extra F3 cols are dropped; the Parquet
# schema is byte-compatible with the backfill's.
#
# ⚠️ ENABLEMENT GATE (READ THIS)
# New-prod F3 `equipment_values` currently carries the ADR-0045 P1 first-boot
# DECODE SPIKES. Appending now would archive corrupted data into the cold store.
# So this job is BUILT but NOT enabled on prod:
#   1. `historian-append.timer` is installed DISABLED by app_init.sh.
#   2. This script hard-gates on HISTORIAN_APPEND_ENABLED=true (default false) —
#      even if the timer were enabled, every run no-ops until the flag flips.
# ENABLE ONLY AFTER: the P1 decode fix is LIVE on prod AND the already-written
# spike rows are corrected. Then set HISTORIAN_APPEND_ENABLED=true in
# /opt/packiot/.env and `systemctl enable --now historian-append.timer`.
# Belt-and-suspenders: HISTORIAN_SPIKE_GUARD=true applies the same
# incr>=val>=floor skip the worker's increment_clamp does — but the REAL fix is
# upstream, this is only a backstop.
#
# USAGE
#   scripts/historian-append.sh                 # default: ent(s) from env, yesterday+overlap
#   scripts/historian-append.sh 3               # one tenant
#   scripts/historian-append.sh 3,4             # a list
#   scripts/historian-append.sh all             # every id_enterprise present in F3
#   scripts/historian-append.sh 3 2026-08-01 2026-08-11   # explicit [start,end) window
#
# ENV (defaults in brackets)
#   HISTORIAN_APPEND_ENABLED   [false]  master gate — must be true to do anything
#   HISTORIAN_APPEND_ENTERPRISES [3]     default tenant set when no arg given
#   HISTORIAN_OVERLAP_DAYS     [2]       re-unload this many days before yesterday
#   HISTORIAN_SPIKE_GUARD      [false]   belt-and-suspenders incr-spike skip
#   HISTORIAN_SPIKE_FLOOR      [1000]    floor for the spike signature (matches worker)
#   HISTORIAN_BUCKET           [packiot-production-historian-<acct>]
#   AWS_REGION                 [us-east-1]
#   DUCKDB                     [auto]    path to the DuckDB CLI
#   SRC_PG_ENVFILE             [/opt/packiot/.env]  where POSTGRES_* creds live
#   Source creds (override the envfile): SRC_PGHOST SRC_PGPORT SRC_PGUSER
#                                        SRC_PGPASSWORD SRC_PGDATABASE
set -euo pipefail

# ── 0. Enablement gate ────────────────────────────────────────────────────────
if [ "${HISTORIAN_APPEND_ENABLED:-false}" != "true" ]; then
  echo "[historian-append] GATED: HISTORIAN_APPEND_ENABLED != true — no-op."
  echo "[historian-append] Enable only AFTER the ADR-0045 P1 decode fix is live on"
  echo "[historian-append] prod and spike rows are corrected (see script header)."
  exit 0
fi

ENT_ARG="${1:-${HISTORIAN_APPEND_ENTERPRISES:-3}}"
START_ARG="${2:-}"
END_ARG="${3:-}"
OVERLAP_DAYS="${HISTORIAN_OVERLAP_DAYS:-2}"
SPIKE_GUARD="${HISTORIAN_SPIKE_GUARD:-false}"
SPIKE_FLOOR="${HISTORIAN_SPIKE_FLOOR:-1000}"

REGION="${AWS_REGION:-us-east-1}"
DUCKDB="${DUCKDB:-}"

# Destination: S3 by default. HISTORIAN_LOCAL_DIR redirects Parquet + watermark to
# a local directory instead — the SAME partition layout, no cloud writes. This is
# the dry-run / staging-verification seam (scripts/historian-append-verify.sh) and
# is NOT used on the prod box (the timer leaves it unset).
LOCAL_DIR="${HISTORIAN_LOCAL_DIR:-}"
if [ -n "$LOCAL_DIR" ]; then
  DEST_BASE="$LOCAL_DIR"
  S3_SECRET_SQL=""   # no S3 secret needed for a local write
else
  ACCT="$(aws sts get-caller-identity --query Account --output text)"
  BUCKET="${HISTORIAN_BUCKET:-packiot-production-historian-${ACCT}}"
  DEST_BASE="s3://${BUCKET}"
  S3_SECRET_SQL="INSTALL httpfs; LOAD httpfs;
CREATE SECRET s3hist (TYPE s3, PROVIDER credential_chain, REGION '${REGION}');"
fi

# Resolve a DuckDB CLI (stable path first for systemd/root, then the user path).
if [ -z "$DUCKDB" ]; then
  for c in /opt/packiot/duckdb/duckdb "$HOME/.duckdb/cli/latest/duckdb" "$(command -v duckdb || true)"; do
    if [ -n "$c" ] && [ -x "$c" ]; then DUCKDB="$c"; break; fi
  done
fi
if [ -z "${DUCKDB:-}" ] || [ ! -x "$DUCKDB" ]; then
  echo "[historian-append] DuckDB CLI not found — installing to ~/.duckdb ..."
  curl -fsSL https://install.duckdb.org | bash
  DUCKDB="$HOME/.duckdb/cli/latest/duckdb"
fi

# ── 1. Source creds = new-prod F3 (NOT legacy) ────────────────────────────────
# Prefer explicit SRC_* overrides; otherwise pull POSTGRES_* from the box .env.
ENVFILE="${SRC_PG_ENVFILE:-/opt/packiot/.env}"
envget() { [ -f "$ENVFILE" ] && grep -m1 "^$1=" "$ENVFILE" | cut -d= -f2- || true; }

PGHOST="${SRC_PGHOST:-$(envget POSTGRES_HOST_UPSTREAM)}"
PGPORT="${SRC_PGPORT:-$(envget POSTGRES_PORT)}"; PGPORT="${PGPORT:-5432}"
PGUSER="${SRC_PGUSER:-$(envget POSTGRES_USER)}"
PGPASSWORD="${SRC_PGPASSWORD:-$(envget POSTGRES_PASSWORD)}"
PGDATABASE="${SRC_PGDATABASE:-$(envget POSTGRES_DB)}"

if [ -z "${PGHOST:-}" ] || [ -z "${PGUSER:-}" ] || [ -z "${PGDATABASE:-}" ]; then
  echo "[historian-append] ERROR: source DB creds missing. Set SRC_PG* or ensure"
  echo "[historian-append] POSTGRES_HOST_UPSTREAM/USER/PASSWORD/DB exist in $ENVFILE." >&2
  exit 2
fi
CONNSTR="host=${PGHOST} port=${PGPORT} user=${PGUSER} password=${PGPASSWORD} dbname=${PGDATABASE} connect_timeout=20"

# ── 2. Resolve the window [START,END) ─────────────────────────────────────────
# Default = (yesterday - OVERLAP_DAYS) .. today  → re-unloads the trailing window
# so late-arriving / backfilled F3 rows are healed. Idempotent: each day is one
# deterministic key, re-written in place (safe for the partition-projection table).
if [ -n "$START_ARG" ] && [ -n "$END_ARG" ]; then
  START="$START_ARG"; END="$END_ARG"
else
  END="$(date -u +%Y-%m-%d)"                                    # today (exclusive)
  START="$(date -u -d "yesterday -${OVERLAP_DAYS} day" +%Y-%m-%d)"
fi

# ── 3. Resolve the tenant set ─────────────────────────────────────────────────
if [ "$ENT_ARG" = "all" ]; then
  echo "[historian-append] resolving all tenants present in F3 ..."
  ENTS="$("$DUCKDB" :memory: -noheader -list <<SQL
INSTALL postgres; LOAD postgres;
ATTACH '${CONNSTR}' AS src (TYPE postgres, READ_ONLY);
SELECT DISTINCT id_enterprise FROM postgres_query('src',
  'SELECT DISTINCT id_enterprise FROM equipment_values
     WHERE id_enterprise IS NOT NULL') ORDER BY 1;
SQL
)"
  ENTS="$(echo "$ENTS" | tr '\n' ' ')"
else
  ENTS="$(echo "$ENT_ARG" | tr ',' ' ')"
fi

echo "[historian-append] source=${PGDATABASE}@${PGHOST} tenants=[${ENTS}] window=[${START},${END}) overlap=${OVERLAP_DAYS}d spike_guard=${SPIKE_GUARD} dest=${DEST_BASE}"

# ── 4. Increment-spike backstop (optional) ────────────────────────────────────
# Mirrors services/oeecloud-worker/internal/writers/increment_clamp.go: when an
# increment consumes the WHOLE absolute totalizer (incr >= val) and that totalizer
# is >= floor, it's the ADR-0045 P1 first-boot signature → emit 0 (not drop). The
# REAL fix is upstream; this is belt-and-suspenders for already-written spikes.
guard() { # $1=incr_col $2=val_col
  if [ "$SPIKE_GUARD" = "true" ]; then
    echo "CASE WHEN CAST($2 AS DOUBLE) >= ${SPIKE_FLOOR} AND CAST($1 AS DOUBLE) >= CAST($2 AS DOUBLE) THEN 0 ELSE CAST($1 AS DOUBLE) END"
  else
    echo "CAST($1 AS DOUBLE)"
  fi
}
NET_INCR="$(guard net_production_incr net_production_val)"
GROSS_INCR="$(guard gross_production_incr gross_production_val)"
SCRAP_INCR="$(guard scrap_incr scrap_val)"
PROC_SCRAP_INCR="$(guard process_scrap_incr process_scrap_val)"

# ── 5. Per-tenant, per-day unload ─────────────────────────────────────────────
for ENT in $ENTS; do
  [ -z "$ENT" ] && continue
  RUN_ROWS=0
  d="$START"
  while [ "$d" \< "$END" ]; do
    next="$(date -u -d "${d} +1 day" +%Y-%m-%d)"
    Y="$(date -u -d "$d" +%Y)"
    M="$(( 10#$(date -u -d "$d" +%m) ))"   # un-padded to match integer projection
    KEY="equipment_values/enterprise=${ENT}/year=${Y}/month=${M}/data-${d}.parquet"
    DEST="${DEST_BASE}/${KEY}"
    [ -n "$LOCAL_DIR" ] && mkdir -p "$(dirname "$DEST")"

    ROWS="$("$DUCKDB" :memory: -noheader -list <<SQL
SET TimeZone='UTC';
INSTALL postgres; LOAD postgres;
${S3_SECRET_SQL}
ATTACH '${CONNSTR}' AS src (TYPE postgres, READ_ONLY);
-- Stage the day once (Timescale-safe streaming scan via Postgres' own planner).
CREATE TEMP TABLE day AS
  SELECT * FROM postgres_query('src',
    'SELECT * FROM equipment_values
       WHERE id_enterprise = ${ENT}
         AND ts_value >= ''${d} 00:00:00+00''
         AND ts_value <  ''${next} 00:00:00+00''');
-- Project EXACTLY the 56 Glue columns, in order, cast to the Glue types.
COPY (
  SELECT
    TRY_CAST(ts_value AS TIMESTAMP)                 AS ts_value,
    TRY_CAST(id_enterprise AS INTEGER)              AS id_enterprise,
    TRY_CAST(id_site AS INTEGER)                    AS id_site,
    TRY_CAST(id_area AS INTEGER)                    AS id_area,
    TRY_CAST(id_equipment AS INTEGER)               AS id_equipment,
    ${NET_INCR}                                     AS net_production_incr,
    ${GROSS_INCR}                                   AS gross_production_incr,
    ${SCRAP_INCR}                                   AS scrap_incr,
    TRY_CAST(speed AS FLOAT)                        AS speed,
    CAST(id_order AS VARCHAR)                       AS id_order,
    TRY_CAST(conversion_factor AS FLOAT)            AS conversion_factor,
    TRY_CAST(number_cavities AS INTEGER)            AS number_cavities,
    CAST(faults AS VARCHAR)                         AS faults,
    CAST(analogs AS VARCHAR)                        AS analogs,
    TRY_CAST(signal_quality AS SMALLINT)            AS signal_quality,
    TRY_CAST(net_production_val AS DOUBLE)          AS net_production_val,
    TRY_CAST(gross_production_val AS DOUBLE)        AS gross_production_val,
    TRY_CAST(scrap_val AS DOUBLE)                   AS scrap_val,
    TRY_CAST(id_shift AS INTEGER)                   AS id_shift,
    TRY_CAST(id_team AS INTEGER)                    AS id_team,
    TRY_CAST(id_shift_hour AS INTEGER)              AS id_shift_hour,
    CAST(box_code AS VARCHAR)                       AS box_code,
    CAST(transaction_code AS VARCHAR)              AS transaction_code,
    TRY_CAST(state AS INTEGER)                      AS state,
    TRY_CAST(mode AS INTEGER)                       AS mode,
    TRY_CAST(id_production_order AS BIGINT)         AS id_production_order,
    TRY_CAST(ts_value_production AS DATE)           AS ts_value_production,
    TRY_CAST(id_equipment_line_infeed AS INTEGER)  AS id_equipment_line_infeed,
    TRY_CAST(id_equipment_line_outfeed AS INTEGER) AS id_equipment_line_outfeed,
    TRY_CAST(net_production_incr_quality AS SMALLINT)   AS net_production_incr_quality,
    TRY_CAST(gross_production_incr_quality AS SMALLINT) AS gross_production_incr_quality,
    TRY_CAST(scrap_incr_quality AS SMALLINT)       AS scrap_incr_quality,
    TRY_CAST(speed_quality AS SMALLINT)            AS speed_quality,
    TRY_CAST(id_order_quality AS SMALLINT)         AS id_order_quality,       -- F3 varchar → NULL if non-numeric
    TRY_CAST(conversion_factor_quality AS SMALLINT) AS conversion_factor_quality,
    TRY_CAST(number_cavities_quality AS SMALLINT)  AS number_cavities_quality,
    TRY_CAST(net_production_val_quality AS SMALLINT) AS net_production_val_quality,
    TRY_CAST(gross_production_val_quality AS SMALLINT) AS gross_production_val_quality,
    TRY_CAST(scrap_val_quality AS SMALLINT)        AS scrap_val_quality,
    TRY_CAST(id_shift_quality AS SMALLINT)         AS id_shift_quality,
    TRY_CAST(state_quality AS SMALLINT)            AS state_quality,
    TRY_CAST(mode_quality AS SMALLINT)             AS mode_quality,
    TRY_CAST(id_production_order_quality AS SMALLINT) AS id_production_order_quality,
    TRY_CAST(ts_value_production_quality AS SMALLINT) AS ts_value_production_quality, -- F3 date → NULL
    TRY_CAST(id_equipment_line_connected AS INTEGER) AS id_equipment_line_connected,
    TRY_CAST(position_in_equipment_line AS SMALLINT) AS position_in_equipment_line,
    TRY_CAST(is_equipment_line_infeed AS SMALLINT)  AS is_equipment_line_infeed,
    TRY_CAST(is_equipment_line_outfeed AS SMALLINT) AS is_equipment_line_outfeed,
    TRY_CAST(process_scrap_incr AS DOUBLE)         AS process_scrap_incr,
    TRY_CAST(process_scrap_val AS DOUBLE)          AS process_scrap_val,
    TRY_CAST(process_scrap_incr_quality AS SMALLINT) AS process_scrap_incr_quality,
    TRY_CAST(process_scrap_val_quality AS SMALLINT)  AS process_scrap_val_quality,
    TRY_CAST(tp_equipment AS SMALLINT)             AS tp_equipment,
    CAST(sub_mode AS VARCHAR)                       AS sub_mode,
    TRY_CAST(ideal_production_speed AS INTEGER)    AS ideal_production_speed,
    TRY_CAST(check_number AS BIGINT)               AS check_number
  FROM day
) TO '${DEST}' (FORMAT PARQUET, COMPRESSION ZSTD, ROW_GROUP_SIZE 122880);
SELECT count(*) FROM day;
SQL
)"
    ROWS="$(echo "$ROWS" | tr -dc '0-9')"; ROWS="${ROWS:-0}"
    RUN_ROWS=$(( RUN_ROWS + ROWS ))
    echo "[historian-append] ent=${ENT} ${d} rows=${ROWS} -> ${DEST}"
    d="$next"
  done

  # ── 6. Watermark / last-run marker (observability; overwrite per tenant) ─────
  WM_JSON="$(printf '{"enterprise":%s,"window_start":"%s","window_end_exclusive":"%s","overlap_days":%s,"spike_guard":%s,"total_rows":%s,"generated_at":"%s"}\n' \
    "$ENT" "$START" "$END" "$OVERLAP_DAYS" "$SPIKE_GUARD" "$RUN_ROWS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  WM_KEY="_watermark/enterprise=${ENT}/last-append.json"
  if [ -n "$LOCAL_DIR" ]; then
    mkdir -p "$(dirname "${DEST_BASE}/${WM_KEY}")"
    printf '%s' "$WM_JSON" > "${DEST_BASE}/${WM_KEY}"
    echo "[historian-append] ent=${ENT} watermark -> ${DEST_BASE}/${WM_KEY} (total_rows=${RUN_ROWS})"
  else
    printf '%s' "$WM_JSON" | aws s3 cp - "${DEST_BASE}/${WM_KEY}" --content-type application/json --region "$REGION" >/dev/null
    echo "[historian-append] ent=${ENT} watermark -> ${DEST_BASE}/${WM_KEY} (total_rows=${RUN_ROWS})"
  fi
done

echo "[historian-append] done tenants=[${ENTS}] window=[${START},${END})"
