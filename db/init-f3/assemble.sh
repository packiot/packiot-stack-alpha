#!/usr/bin/env bash
# db/init-f3/assemble.sh — assemble the F3 (refactored single-flow) schema as the
# `public` schema of a FRESH database. This is the greenfield-prod DB-init path
# (roadmap W1.4): a brand-new prod DB must be BORN with the end-state schema that
# staging's `packiot_shadow` carries, WITHOUT the F1/F2 legacy or the long
# ADR-0012/0032 migration.
#
# ⚠ READ db/init-f3/README.md FIRST. This loader concatenates the canonical F3
# source fragments in dependency order, but those fragments have DIVERGED from
# live `packiot_shadow` (00-schema is a non-runnable dump; 22-agg-views makes
# plain views not caggs; there is no single clean base-hierarchy DDL file). The
# AUTHORITATIVE, byte-faithful method is a curated schema-only dump of live
# `packiot_shadow` (README §4). This loader is the reviewable scaffold + the
# thing the parity gate (scripts/prod-f3-schema-parity-check.sh) measures against.
#
# Usage:
#   PGHOST=... PGUSER=postgres PGDATABASE=packiot ./db/init-f3/assemble.sh
#   ./db/init-f3/assemble.sh 'postgresql://postgres:postgres@localhost:5599/packiot'
#   CONTINUE_ON_ERROR=1 ./db/init-f3/assemble.sh <dsn>   # best-effort, log & continue
#
# After it runs, PROVE it:
#   CANDIDATE_DSN=<dsn> ./scripts/prod-f3-schema-parity-check.sh gate
set -uo pipefail

DSN="${1:-}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENR="$ROOT/edge-node-red/db"
MIG="$ROOT/docs/adr/reference/migrations"
INIT="$ROOT/db/init"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-1}"

psqlf() {  # psqlf <file>
  local f="$1"
  [ -f "$f" ] || { echo "  [MISSING FILE] $f"; return 1; }
  local stop="-v ON_ERROR_STOP=1"; [ "$CONTINUE_ON_ERROR" = "1" ] && stop=""
  if [ -n "$DSN" ]; then psql "$DSN" $stop -qf "$f"; else psql $stop -qf "$f"; fi
}
psqls() {  # psqls <sql> — inline SQL (e.g. __SCH__-substituted)
  if [ -n "$DSN" ]; then printf '%s' "$1" | psql "$DSN" -q; else printf '%s' "$1" | psql -q; fi
}
step() { echo; echo "── $* ──"; }

# ── 1. Extensions ─────────────────────────────────────────────────────────────
step "1. extensions"
psqls "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE; CREATE EXTENSION IF NOT EXISTS pg_cron;"

# ── 2. Base hierarchy + reference tables ──────────────────────────────────────
# ⚠ GAP: there is no canonical F3 base-hierarchy DDL FILE. edge-node-red/db/00
# is a non-runnable introspection dump. db/init/00-schema.sql is the dev schema
# (real DDL) but explicitly OMITS agg_* + _quality columns — an INCOMPLETE base.
# We seed from it to get enterprises/sites/areas/equipments/packml_register/
# shifts/production_orders/equipment_values, then layer parity on top. The
# residual is exactly what the parity gate reports (README §4/§5).
step "2. base hierarchy + reference (dev schema — INCOMPLETE, see README)"
psqlf "$INIT/00-schema.sql"

# ── 3. companion / missing tables + rollup grain tables ───────────────────────
# equipment_runtime_shift/_1hour/_1day/_1week/_1month, plc_events, scanned_boxes,
# production_targets, teams, monitoramento_execucao_functions, …
step "3. missing tables + rollup grains (db/10)"
psqlf "$ENR/10-missing-tables.sql"
step "3b. UNS snapshot tables (db/11)"
psqlf "$ENR/11-uns-tables.sql"

# ── 4. Hasura parity relations + typed stubs + FK + type parity ───────────────
step "4a. hasura metadata parity stubs (db/17)"
psqlf "$ENR/17-hasura-metadata-parity.sql"
step "4b. hasura full parity: h_piot_* library + tracked fns (db/19)"
psqlf "$ENR/19-hasura-full-parity.sql"
step "4c. OEE engine transplant + piot_create_*_runtime provisioning fns (db/20)"
psqlf "$ENR/20-oee-engine-parity.sql"
step "4d. FK parity (db/18)"
psqlf "$ENR/18-hasura-fk-parity.sql"
step "4e. column type parity (db/21)"
psqlf "$ENR/21-column-type-parity.sql"
step "4f. column parity ADD COLUMNs (db/09)"
psqlf "$ENR/09-column-parity.sql"

# ── 5. REAL continuous-aggregate layer (NOT db/22's plain views) ──────────────
# db/22-agg-views.sql builds agg_*/ca_* as plain real-time VIEWS because staging
# F1 has no hypertables. F3 wants REAL caggs on a hypertable equipment_values.
# Source of truth = the 0012 F3 cagg migrations. ⚠ these were authored against
# an already-populated packiot_shadow (create_hypertable(..., migrate_data)); on
# an empty DB they still create the hypertable + cagg definitions.
step "5a. raw write-target hypertables (0012-phase3-writer-tables)"
psqlf "$MIG/0012-phase3-writer-tables.sql"
step "5b. F3 cagg layer — agg_*/ca_agg_* as real continuous aggregates (0012-f3-cagg-layer)"
psqlf "$MIG/0012-f3-cagg-layer.sql"

# ── 6. Read-plane surface + refdata + operator/Hasura companions ──────────────
step "6a. gapfill aggregate + stub-table→view conversions (db/23)"
psqlf "$ENR/23-gapfill-and-view-conversions.sql"
step "6b. operator views (db/04)"
psqlf "$ENR/04-operator-views.sql"
step "6c. Hasura SRF return-type tables + procs (db/05)"
psqlf "$ENR/05-staging-functions.sql"
step "6d. shifts + shift-resolver fns (db/06)"
psqlf "$ENR/06-staging-shifts.sql"
step "6e. Hasura SRF companion tables (db/07)"
psqlf "$ENR/07-staging-companion-tables.sql"
step "6f. refdata SQL deps on F3 (0018-f3-refdata-deps)"
psqlf "$MIG/0018-f3-refdata-deps.sql"
step "6g. refdata read-plane views (db/27)"
psqlf "$ENR/27-refdata-views.sql"
step "6h. refdata tables — dashboard_config (db/28; staging seed is prod-inert)"
psqlf "$ENR/28-refdata-tables.sql"
step "6i. F3 analytics port — 26 h_piot fns + 6 config relations (db/29)"
psqlf "$ENR/29-f3-analytics-port.sql"
step "6j. F3 front4 dataset objects — v_report_downtimes (db/30)"
psqlf "$ENR/30-f3-front4-dataset-objects.sql"
step "6k. F3 front4 Category-C column parity (db/31)"
psqlf "$ENR/31-f3-front4-cat-c-objects.sql"
step "6l. Cognito per-user tenant key (db/32)"
psqlf "$ENR/32-cognito-user-id.sql"
step "6m. reasons dimension (ADR-0039 R5 — downtime_reason/scrap_reason dims)"
psqlf "$MIG/0039-reasons-dimension.sql"

# ── 7. F3-critical fixup: bigint-widen week/month aggregate columns ───────────
# int4 SUM of daily counters overflows on high-throughput lines (SQLSTATE 22003)
# and denies the ENTIRE rollup UPDATE → silently-stale OEE. Greenfield prod must
# be born with these as bigint. Source is __SCH__-parameterized; target = public.
step "7. bigint-widen refactored rollup columns (db/init/02, __SCH__→public)"
if [ -f "$INIT/02-refactored-rollup-bigint-widen.sql" ]; then
  psqls "$(sed 's/__SCH__/public/g' "$INIT/02-refactored-rollup-bigint-widen.sql")"
fi

# ── 8. (data cleanup — NO-OP on a fresh empty DB) ─────────────────────────────
# db/init/03-purge-nonstate-event-pollution.sql deletes pre-existing polluted
# open events; on an empty greenfield DB there is nothing to purge. The paired
# guard (BuildEventMint status_type=4 gate) lives in the worker, not here.

echo
echo "── assembly complete. Now prove it: ──"
echo "  CANDIDATE_DSN=<dsn> ./scripts/prod-f3-schema-parity-check.sh gate"
