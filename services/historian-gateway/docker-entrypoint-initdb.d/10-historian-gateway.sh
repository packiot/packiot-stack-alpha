#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# historian-gateway init — runs once on a fresh pg_duckdb data volume.
#
# Builds the TRANSPARENT HOT+COLD UNION that lets front4 / Superset / any tool
# query old timestamps with plain SQL:
#
#   ev_all  =  live.equipment_values   (postgres_fdw -> the timescaledb hypertable, HOT)
#           UNION ALL
#              hist                     (pg_duckdb  -> S3 Parquet historian,        COLD)
#
# WHY A SEPARATE GATEWAY (not pg_duckdb inside the timescaledb instance):
#   * The staging/prod DB image is Alpine/musl (timescale/timescaledb:*-pg15);
#     pg_duckdb ships glibc and bundles DuckDB (large C++) — no musl build.
#   * Keeps heavy historian scans off the operational OLTP instance.
#   Consumers repoint ONE connection host to this gateway; SQL is unchanged.
#
# COLD side reads ONLY *-legacy.parquet (the deep-remapped legacy backfill),
# which is pre-cutover by construction, so `UNION ALL` needs no per-enterprise
# cutover boundary and never double-counts the append-job's post-cutover files.
#
# TENANT RLS: pg_duckdb CANNOT evaluate PG session GUC / STABLE functions during
# pushdown (they get shipped into DuckDB, which has no PG context). So the tenant
# MUST arrive as a LITERAL/param. Superset's native RLS injects it as a literal;
# read-api adds `id_enterprise = <id>` from its already-known tenant. Do NOT rely
# on a `current_setting()`-based policy for the cold path.
#
# Required env (see compose.historian-gateway.yml):
#   FDW_HOST FDW_PORT FDW_DB FDW_USER FDW_PASS   — the live timescaledb
#   HISTORIAN_BUCKET AWS_REGION                   — S3 historian
#   HIST_AWS_KEY HIST_AWS_SECRET                  — scoped read-only S3 key
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- HOT: live timescaledb hypertable via postgres_fdw (chunk-exclusion pushdown
-- happens on the remote when a ts_value predicate is supplied).
CREATE SERVER IF NOT EXISTS live_pg FOREIGN DATA WRAPPER postgres_fdw
  OPTIONS (host '${FDW_HOST}', port '${FDW_PORT:-5432}', dbname '${FDW_DB}');
DROP USER MAPPING IF EXISTS FOR ${POSTGRES_USER} SERVER live_pg;
CREATE USER MAPPING FOR ${POSTGRES_USER} SERVER live_pg
  OPTIONS (user '${FDW_USER}', password '${FDW_PASS}');
CREATE SCHEMA IF NOT EXISTS live;
IMPORT FOREIGN SCHEMA public LIMIT TO (equipment_values) FROM SERVER live_pg INTO live;

-- COLD: S3 Parquet historian via pg_duckdb. Scoped read-only key (instance-role
-- credential_chain is unavailable: the DB enforces IMDSv2 and DuckDB's aws
-- extension cannot fetch v2 creds through the docker hop).
SELECT duckdb.create_simple_secret('S3','${HIST_AWS_KEY}','${HIST_AWS_SECRET}','','${AWS_REGION:-us-east-1}');

-- Only *-legacy.parquet == the deep-remapped legacy backfill (pre-cutover).
CREATE OR REPLACE VIEW hist AS
SELECT r['ts_value']::timestamp               AS ts_value,
       r['enterprise']::int                   AS id_enterprise,
       r['year']::int                         AS year,
       r['month']::int                        AS month,
       r['id_equipment']::int                 AS id_equipment,
       r['gross_production_incr']::double precision AS gross_production_incr,
       r['net_production_incr']::double precision   AS net_production_incr
FROM read_parquet('s3://${HISTORIAN_BUCKET}/equipment_values/*/*/*/*-legacy.parquet',
                  hive_partitioning => true) r;

-- Unified hot+cold. Plain UNION ALL is correct: hist is pre-cutover legacy,
-- live carries each tenant from its F3 cutover onward — disjoint by construction.
CREATE OR REPLACE VIEW ev_all AS
  SELECT ts_value, id_enterprise, id_equipment, gross_production_incr, net_production_incr
    FROM live.equipment_values
  UNION ALL
  SELECT ts_value, id_enterprise, id_equipment, gross_production_incr, net_production_incr
    FROM hist;
SQL

echo "[historian-gateway] init complete: ev_all (live FDW + S3 historian) ready"
