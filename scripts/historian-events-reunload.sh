#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# historian-events-reunload.sh — id-remap the COLD equipment_events archive from
# the legacy id-space into the F3 id-space, on disk (task #227 / §8-EE step 1).
#
# WHY: the cold EE archive was backfilled with LEGACY enterprise ids
# (scripts/historian-events-backfill.sh writes enterprise=<legacy id>), but the
# hot F3 analytics DB and the EV cold archive are F3 id-space. To union cold EE
# with hot EE (equipment_events_all) and fence it by the F3 id_enterprise a tenant
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
#       (the EV cold files carry this too; the gateway `equipment_values` view reads it, so it
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
# double-count blocker — it can be excluded from equipment_events_all cleanly.)
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
  WROTE=$(( ${WROTE:-0} + 1 ))
done
log "=== EE re-unload DONE  ent $SRC_ENT -> $DST_ENT  (partitions written: ${WROTE:-0}) ==="

# ── PROMOTE: allow-list + EE cutover refresh (t271 + R3 #270) ────────────────────
# Promoting a tenant writes NEW *-legacy.parquet under equipment_events/enterprise=
# $DST_ENT/, which the gateway `equipment_events` glob serves. But equipment_events_all only serves
# a tenant's cold EE when it is ee_promoted in promoted_enterprise (t271 allow-
# list — the SOLE cold-side tenant-isolation gate). So promotion = TWO gateway steps:
#   1) flip ee_promoted=true for DST_ENT (this is the act of promotion — do it ONLY
#      for a VERIFIED remap: cold id_equipment ⊆ core.equipments(DST_ENT), which the
#      operator confirms per the header rules; the script does not auto-verify).
#   2) refresh ev_events_cutover — HOT-ANCHORED, cold owns ts_event < cutover; a
#      missing/stale boundary DOUBLE-COUNTS the overlap. The refresh joins the allow-
#      list, so step 1 MUST precede it or DST_ENT gets no cutover row.
# Both read only the hot FDW / tiny tables (cheap), safe to run every time. FAIL the
# job if either step errors (a silent partial promotion is a correctness risk).
if [ "${WROTE:-0}" -gt 0 ]; then
  GW="${GATEWAY_CONTAINER:-hist-gateway}"
  GW_DB="${GATEWAY_DB:-postgres}"
  GW_USER="${GATEWAY_USER:-postgres}"
  log "promoting DST_ENT=$DST_ENT (ee_promoted) + refreshing ev_events_cutover on '$GW' …"
  if ! docker exec -i "$GW" psql -v ON_ERROR_STOP=1 -U "$GW_USER" -d "$GW_DB" -v dst="$DST_ENT" >>"$LOG" 2>&1 <<'PROMOTE_SQL'
-- 1) mark the tenant EE-promoted (id-space verified by the operator per header rules)
INSERT INTO promoted_enterprise (id_enterprise, ee_promoted, provenance, note)
VALUES (:dst, true, 'ee_reunload',
        'promoted by historian-events-reunload.sh — cold EE re-keyed to F3 id ' || :dst)
ON CONFLICT (id_enterprise) DO UPDATE SET ee_promoted = true;
-- 2) refresh the EE boundary for now-promoted enterprises (joins the allow-list)
INSERT INTO ev_events_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT lv.id_enterprise, min(lv.ts_event)::timestamp, now()
  FROM live.equipment_events lv
  JOIN promoted_enterprise p ON p.id_enterprise = lv.id_enterprise AND p.ee_promoted
 WHERE lv.id_enterprise IS NOT NULL GROUP BY lv.id_enterprise
ON CONFLICT (id_enterprise) DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
PROMOTE_SQL
  then
    log "PROMOTE-FAIL: could not promote/refresh DST_ENT=$DST_ENT on the gateway."
    log "  Its EE cold is globbed by equipment_events but NOT allow-listed/bounded => equipment_events_all"
    log "  will serve nothing (safe) OR, if partially applied, could double-count. Run the"
    log "  allow-list upsert + refresh-ee-cutover.sql on the gateway before serving this tenant."
    exit 1
  fi
  log "DST_ENT=$DST_ENT promoted (ee_promoted=true) + ev_events_cutover refreshed OK"
else
  log "no partitions written (all skipped) — no promotion/refresh required"
fi
