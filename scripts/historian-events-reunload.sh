#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# historian-events-reunload.sh — id-remap the COLD equipment_events archive from
# the legacy id-space into the F3 id-space, on disk (task #227 / §8-EE step 1).
#
# WHY: the cold EE archive was backfilled with LEGACY enterprise ids
# (scripts/historian-events-backfill.sh writes enterprise=<legacy id>), but the
# hot F3 analytics DB and the EV cold archive are F3 id-space. To union cold EE
# with hot EE (ev_all_events) and fence it by the F3 id_enterprise a tenant
# actually queries, the cold EE must be re-keyed to F3 on disk — the same
# "partition-key IS the F3 id, no in-view CASE" convention the EV cold archive
# uses (docs/plans/historian-clean-schema-redesign.md §3.2).
#
# WHAT it does, per (year,month) partition of SRC_ENT:
#   read  s3://$BUCKET/equipment_events/enterprise=$SRC_ENT/year=Y/month=M/*-legacy.parquet
#   write s3://$BUCKET/equipment_events/enterprise=$DST_ENT/year=Y/month=M/<same name>
#   with BOTH enterprise identifiers rewritten to $DST_ENT:
#     - id_enterprise (int)     — the real column consumers read
#     - enterprise    (bigint)  — the redundant file-copy of the hive path key
#       (the EV cold files carry this too; the gateway `hist` view reads it, so it
#        MUST equal the path key — verified 2026-09-08).
#   year/month are left untouched (already correct).
#
# SAFE + REVERSIBLE:
#   * standalone DuckDB CLI (NOT pg_duckdb) — CTAS/COPY-from-parquet is only a
#     backend-crash hazard *inside pg_duckdb*; the standalone CLI is what the
#     backfill scripts already use.
#   * writes to a NEW enterprise=$DST_ENT prefix; the SRC enterprise=$SRC_ENT
#     prefix is left INTACT as the rollback source (S3 versioning is OFF on this
#     bucket, so the untouched source IS the backup). To undo: delete the
#     enterprise=$DST_ENT EE prefix.
#   * idempotent/resumable: skips a partition whose DST file already exists.
#   * per-file row-count parity gate (src rows == dst rows) + a one-shot
#     DESCRIBE schema-identity assert on the first partition.
#
# NOTE ON SCOPE: only enterprise-only remaps are safe here (CPACK 1→3 — the
# equipment ids are STABLE across the remap, verified). Incoplast 33→4 is a DEEP
# remap that also re-keyed equipment ids (990015–990018) and dropped line
# aggregates; that equipment map is NOT in tracked code, so a naive enterprise
# relabel would leave cold events with equipment ids that do not join F3 ent-4.
# Do NOT run this for 33→4 without the equipment-id map. (33 is also not a
# double-count blocker — it can be excluded from ev_all_events cleanly.)
#
# Usage (on a box with the DuckDB CLI + S3 write to the historian bucket):
#   SRC_ENT=1 DST_ENT=3 BUCKET=packiot-staging-historian-639178078294 \
#     bash scripts/historian-events-reunload.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export HOME=/tmp
DUCKDB="${DUCKDB:-/.duckdb/cli/latest/duckdb}"
BUCKET="${BUCKET:?set BUCKET}"
SRC_ENT="${SRC_ENT:?set SRC_ENT (legacy id)}"
DST_ENT="${DST_ENT:?set DST_ENT (F3 id)}"
REGION="${AWS_REGION:-us-east-1}"
LOG="${LOG:-/tmp/historian-events-reunload-${SRC_ENT}-to-${DST_ENT}.log}"
SEC="SET home_directory='/tmp'; INSTALL httpfs; LOAD httpfs; CREATE SECRET s (TYPE S3, PROVIDER credential_chain, REGION '$REGION');"
log(){ echo "$(date -u +%Y-%m-%dT%H:%M:%S) $*" | tee -a "$LOG"; }
DESC_DONE=0

log "=== EE re-unload START  ent $SRC_ENT -> $DST_ENT  bucket=$BUCKET ==="

# Enumerate the SRC partitions from S3 (year=/month=/file).
mapfile -t KEYS < <(aws s3 ls "s3://$BUCKET/equipment_events/enterprise=$SRC_ENT/" --recursive \
                     | awk '{print $4}' | grep 'legacy.parquet$')
log "found ${#KEYS[@]} source partition file(s)"

for key in "${KEYS[@]}"; do
  # key = equipment_events/enterprise=1/year=2026/month=9/data-2026-09-legacy.parquet
  Y=$(echo "$key"  | sed -E 's#.*/year=([0-9]+)/.*#\1#')
  Mo=$(echo "$key" | sed -E 's#.*/month=([0-9]+)/.*#\1#')
  fname=$(basename "$key")
  SRC="s3://$BUCKET/$key"
  DST="s3://$BUCKET/equipment_events/enterprise=$DST_ENT/year=$Y/month=$Mo/$fname"

  if aws s3 ls "$DST" >/dev/null 2>&1; then log "SKIP  $Y-$Mo (dst exists)"; continue; fi

  # remap write
  if ! "$DUCKDB" -c "$SEC
COPY (SELECT * REPLACE ($DST_ENT::int AS id_enterprise, $DST_ENT::bigint AS enterprise)
      FROM read_parquet('$SRC')) TO '$DST' (FORMAT PARQUET, COMPRESSION ZSTD);" >>"$LOG" 2>&1; then
    log "FAIL  $Y-$Mo COPY"; continue
  fi

  # per-file parity gate
  SN=$("$DUCKDB" -noheader -list -c "$SEC SELECT count(*) FROM read_parquet('$SRC');" 2>>"$LOG" | tail -1)
  DN=$("$DUCKDB" -noheader -list -c "$SEC SELECT count(*) FROM read_parquet('$DST');" 2>>"$LOG" | tail -1)
  DE=$("$DUCKDB" -noheader -list -c "$SEC SELECT string_agg(DISTINCT id_enterprise::varchar,',') FROM read_parquet('$DST');" 2>>"$LOG" | tail -1)
  if [ "$SN" != "$DN" ] || [ "$DE" != "$DST_ENT" ]; then
    log "PARITY-FAIL $Y-$Mo src=$SN dst=$DN dst_ent=$DE — removing bad dst"
    aws s3 rm "$DST" >/dev/null 2>&1; continue
  fi

  # one-shot schema-identity assert (first good partition)
  if [ "$DESC_DONE" = 0 ]; then
    "$DUCKDB" -noheader -list -c "$SEC DESCRIBE SELECT * FROM read_parquet('$SRC');" 2>>"$LOG" | sort > /tmp/_ru_src.txt
    "$DUCKDB" -noheader -list -c "$SEC DESCRIBE SELECT * FROM read_parquet('$DST');" 2>>"$LOG" | sort > /tmp/_ru_dst.txt
    if diff -q /tmp/_ru_src.txt /tmp/_ru_dst.txt >/dev/null; then log "SCHEMA-IDENTICAL (DESCRIBE match)"; else log "SCHEMA-DIFF (see /tmp/_ru_*.txt)"; fi
    DESC_DONE=1
  fi

  log "OK    $Y-$Mo rows=$DN id_enterprise=$DE"
done
log "=== EE re-unload DONE  ent $SRC_ENT -> $DST_ENT ==="
