#!/usr/bin/env bash
# repair-line-scrap-and-unbacked.sh — staging data repair for the Phase-9 line-scrap defects (#1650) and the
# 2026-10-06 16:32 unbacked-increment burst. STAGING DATA ONLY: prod is promoted from its own data (transplant), so
# nothing here is ever replayed there.
#
#   C  impossible single-row increments (|incr| > LIMIT in one ~15 s sample, NOT backed by the row's own totalizer:
#      stale upstream baseline after the 10-06 disk-full restart) → 0, the 10-01 precedent (ops._fix_unbacked_20261001).
#      A totalizer-backed lump is real production and is kept (CER400 publishes consumed only at births).
#   AB line scrap (tp=3): the line's scrap is Σ first-machine consumed − Σ last-machine processed. Phase 9 lost
#      deltas to the same-second upsert (A) and derived −Σnet for lines without an infeed (B). For every line-day
#      whose stored Σscrap ≠ Σ(gross − net), set per row scrap := gross − net when the line-day has an infeed
#      (Σgross > 0), else NULL. Sums become exact; gold is unaffected by AB (line-lead derives line scrap from the
#      member machines), only silver/cagg readers are.
#   then refresh the silver caggs for every touched day and flag gold (hour/shift/day) + PO runtimes for C's days.
#
# Every changed row is snapshotted first in ops._fix_line_scrap_20261009 (old + new values). A not-yet-applied
# snapshot is refreshed on re-run (a DRY_RUN's AB snapshot predates C's repair); applied rows are never touched again,
# so the first old values survive for the undo. applied_at is set only from a read-back. Compressed chunks: plain WHERE updates per equipment-day (one
# id_equipment segment), never UPDATE … FROM (reports 0 rows on compressed chunks, 10-01) and never decompress_chunk.
#
#   PSQL='docker exec -i timescaledb psql -U postgres -d packiot_analytics' ENTS=3,2000003 DAYS=25 bash repair-…sh
#   DRY_RUN=1 → snapshot + report only.
# Undo:
#   UPDATE silver.equipment_values v SET gross_production_incr = f.old_gross, net_production_incr = f.old_net,
#          scrap_incr = f.old_scrap FROM ops._fix_line_scrap_20261009 f   -- per equipment-day for compressed chunks
#    WHERE v.id_equipment = f.id_equipment AND v.ts_value = f.ts_value;
set -euo pipefail
ENTS="${ENTS:?e.g. 3,2000003}"; DAYS="${DAYS:-25}"; LIMIT="${LIMIT:-20000}"; DRY_RUN="${DRY_RUN:-0}"
PSQL="${PSQL:?psql command reaching packiot_analytics}"
P(){ $PSQL -X -v ON_ERROR_STOP=1 -At -c "SET statement_timeout='10min'; SET lock_timeout='10s'; $1" < /dev/null | tail -1; }
Q(){ $PSQL -X -v ON_ERROR_STOP=1 -At -F ' ' -c "SET statement_timeout='10min'; $1" < /dev/null | sed 1d; }
log(){ echo "[$(date -u +%T)] $*"; }
FIX=ops._fix_line_scrap_20261009
RUN_START=$(P "SELECT now()")   # caggs/flags below only for rows applied in THIS run

P "CREATE TABLE IF NOT EXISTS $FIX (
     id_enterprise int, id_equipment int, ts_value timestamptz, kind text,
     old_gross real, old_net real, old_scrap real, new_gross real, new_net real, new_scrap real,
     snapped_at timestamptz DEFAULT now(), applied_at timestamptz,
     PRIMARY KEY (id_equipment, ts_value, kind))" >/dev/null

# ── C: impossible single-row increments → 0 ───────────────────────────────────────────────────────────────────
N=$(P "INSERT INTO $FIX (id_enterprise, id_equipment, ts_value, kind, old_gross, old_net, old_scrap, new_gross, new_net, new_scrap)
       SELECT v.id_enterprise, v.id_equipment, v.ts_value, 'unbacked',
              v.gross_production_incr, v.net_production_incr, v.scrap_incr,
              CASE WHEN abs(v.gross_production_incr) > $LIMIT THEN 0 ELSE v.gross_production_incr END,
              CASE WHEN abs(v.net_production_incr)   > $LIMIT THEN 0 ELSE v.net_production_incr END,
              CASE WHEN abs(v.scrap_incr)            > $LIMIT THEN 0 ELSE v.scrap_incr END
         FROM silver.equipment_values v
        WHERE v.id_enterprise = ANY('{$ENTS}'::int[]) AND v.ts_value >= now() - interval '$DAYS days'
          AND (abs(v.gross_production_incr) > $LIMIT OR abs(v.net_production_incr) > $LIMIT OR abs(v.scrap_incr) > $LIMIT)
          -- NOT when the row's own totalizer moved by the increment: that is real, lumpy production (CER400's consumed
          -- counter is only published at (re)births, so each lump = production since the previous birth; staging run
          -- 1 zeroed a backed +43,857 and it had to be restored, 2026-10-09). Magnitude alone is not evidence.
          AND NOT coalesce(abs(v.gross_production_incr) > $LIMIT AND abs((v.gross_production_total - (SELECT p.gross_production_total
                  FROM silver.equipment_values p WHERE p.id_equipment = v.id_equipment AND p.ts_value < v.ts_value
                   AND p.gross_production_total IS NOT NULL ORDER BY p.ts_value DESC LIMIT 1)) - v.gross_production_incr) <= 100, false)
          AND NOT coalesce(abs(v.net_production_incr) > $LIMIT AND abs((v.net_production_total - (SELECT p.net_production_total
                  FROM silver.equipment_values p WHERE p.id_equipment = v.id_equipment AND p.ts_value < v.ts_value
                   AND p.net_production_total IS NOT NULL ORDER BY p.ts_value DESC LIMIT 1)) - v.net_production_incr) <= 100, false)
       ON CONFLICT (id_equipment, ts_value, kind) DO UPDATE
         SET old_gross = EXCLUDED.old_gross, old_net = EXCLUDED.old_net, old_scrap = EXCLUDED.old_scrap,
             new_gross = EXCLUDED.new_gross, new_net = EXCLUDED.new_net, new_scrap = EXCLUDED.new_scrap, snapped_at = now()
         WHERE $FIX.applied_at IS NULL")
log "C snapshot: $N impossible-increment rows"
if [ "$DRY_RUN" != 1 ]; then
  while read -r eq ts; do
    [ -n "$eq" ] || continue
    U=$(P "WITH f AS (SELECT * FROM $FIX WHERE kind='unbacked' AND id_equipment=$eq AND ts_value='$ts')
           UPDATE silver.equipment_values v
              SET gross_production_incr = (SELECT new_gross FROM f), net_production_incr = (SELECT new_net FROM f),
                  scrap_incr = (SELECT new_scrap FROM f)
            WHERE v.id_equipment = $eq AND v.ts_value = '$ts'
              AND v.gross_production_incr IS NOT DISTINCT FROM (SELECT old_gross FROM f)
              AND v.net_production_incr   IS NOT DISTINCT FROM (SELECT old_net FROM f)")
    [ "$U" = "UPDATE 1" ] && P "UPDATE $FIX SET applied_at = now() WHERE kind='unbacked' AND id_equipment=$eq AND ts_value='$ts'" >/dev/null
  done < <(Q "SELECT id_equipment, ts_value FROM $FIX WHERE kind='unbacked' AND applied_at IS NULL ORDER BY ts_value")
  log "C applied: $(P "SELECT count(*) FROM $FIX WHERE kind='unbacked' AND applied_at IS NOT NULL")"
fi

# ── AB: line-days whose Σscrap ≠ Σ(gross − net) ───────────────────────────────────────────────────────────────
mapfile -t LINEDAYS < <(Q "
  SELECT v.id_equipment, date_trunc('day', v.ts_value)::date
    FROM silver.equipment_values v JOIN core.equipments e USING (id_equipment)
   WHERE v.id_enterprise = ANY('{$ENTS}'::int[]) AND e.tp_equipment = 3 AND v.ts_value >= now() - interval '$DAYS days'
   GROUP BY 1, 2
  HAVING (coalesce(sum(v.gross_production_incr),0) > 0
          AND abs(coalesce(sum(v.scrap_incr),0) - (coalesce(sum(v.gross_production_incr),0) - coalesce(sum(v.net_production_incr),0))) > 50)
      OR (coalesce(sum(v.gross_production_incr),0) = 0 AND count(v.scrap_incr) > 0)
   ORDER BY 2, 1")
log "AB: ${#LINEDAYS[@]} line-days to repair"
for ld in "${LINEDAYS[@]}"; do
  read -r eq day <<<"$ld"
  # Day bounds as LITERAL timestamps. A stable bound (`ts_value < date 'X' + 1`, TimeZone-dependent cast) makes an
  # UPDATE on a COMPRESSED chunk match 0 rows on TimescaleDB 2.27 (staging 2026-10-09, reproduced in a rolled-back
  # transaction: date-expression bound → UPDATE 0, literal bound → UPDATE 7981); SELECTs are unaffected.
  NEXT=$(date -u -d "$day + 1 day" +%F)
  # infeed = the line-day has gross at all (a constant, so the UPDATE below is a plain-WHERE, join-free statement)
  INFEED=$(P "SELECT coalesce(sum(gross_production_incr),0) > 0 FROM silver.equipment_values
               WHERE id_equipment=$eq AND ts_value >= '$day' AND ts_value < '$NEXT'")
  [ "$INFEED" = t ] && TGT="CASE WHEN v.gross_production_incr IS NULL AND v.net_production_incr IS NULL THEN NULL
                                 ELSE coalesce(v.gross_production_incr,0) - coalesce(v.net_production_incr,0) END" \
                    || TGT="NULL::real"
  N=$(P "INSERT INTO $FIX (id_enterprise, id_equipment, ts_value, kind, old_gross, old_net, old_scrap, new_gross, new_net, new_scrap)
         SELECT v.id_enterprise, v.id_equipment, v.ts_value, 'line_scrap', v.gross_production_incr, v.net_production_incr,
                v.scrap_incr, v.gross_production_incr, v.net_production_incr, $TGT
           FROM silver.equipment_values v
          WHERE v.id_equipment=$eq AND v.ts_value >= '$day' AND v.ts_value < '$NEXT'
            AND v.scrap_incr IS DISTINCT FROM ($TGT)
         ON CONFLICT (id_equipment, ts_value, kind) DO UPDATE
         SET old_gross = EXCLUDED.old_gross, old_net = EXCLUDED.old_net, old_scrap = EXCLUDED.old_scrap,
             new_gross = EXCLUDED.new_gross, new_net = EXCLUDED.new_net, new_scrap = EXCLUDED.new_scrap, snapped_at = now()
         WHERE $FIX.applied_at IS NULL")
  if [ "$DRY_RUN" = 1 ]; then log "  eq $eq $day infeed=$INFEED: $N rows (dry run)"; continue; fi
  U=$(P "UPDATE silver.equipment_values v SET scrap_incr = $TGT
          WHERE v.id_equipment=$eq AND v.ts_value >= '$day' AND v.ts_value < '$NEXT'
            AND v.scrap_incr IS DISTINCT FROM ($TGT)")
  # applied = read back: the row now holds the snapshotted new value
  P "UPDATE $FIX f SET applied_at = now() FROM silver.equipment_values v
      WHERE f.kind='line_scrap' AND f.id_equipment=$eq AND f.ts_value >= '$day' AND f.ts_value < '$NEXT'
        AND f.applied_at IS NULL AND v.id_equipment=f.id_equipment AND v.ts_value=f.ts_value
        AND v.scrap_incr IS NOT DISTINCT FROM f.new_scrap" >/dev/null
  log "  eq $eq $day infeed=$INFEED: snapshot $N, $U"
done
[ "$DRY_RUN" = 1 ] && { log "dry run: nothing changed"; exit 0; }
# snapshots never applied (an earlier DRY_RUN, or a line-day that C's repair brought back within tolerance) still
# hold the row's current value as old_scrap: drop them so the table lists exactly what changed
D=$(P "DELETE FROM $FIX f USING silver.equipment_values v
        WHERE f.applied_at IS NULL AND v.id_equipment = f.id_equipment AND v.ts_value = f.ts_value
          AND v.scrap_incr IS NOT DISTINCT FROM f.old_scrap
          AND (f.kind = 'line_scrap'  -- AB only ever changes scrap
               OR (v.gross_production_incr IS NOT DISTINCT FROM f.old_gross AND v.net_production_incr IS NOT DISTINCT FROM f.old_net))")
log "unapplied snapshots dropped: $D"

# ── caggs: hierarchical 1min → 1hour, per touched day ─────────────────────────────────────────────────────────
mapfile -t TDAYS < <(Q "SELECT DISTINCT date_trunc('day', ts_value)::date FROM $FIX WHERE applied_at >= '$RUN_START' ORDER BY 1")
for day in "${TDAYS[@]}"; do
  for cagg in silver.agg_equipment_values_1min silver.equipment_metrics_1min silver.equipment_categorical_1min \
              silver.agg_equipment_values_1hour silver.equipment_categorical_1hour; do
    $PSQL -X -v ON_ERROR_STOP=1 -At -c "SET statement_timeout='20min'" \
      -c "CALL refresh_continuous_aggregate('$cagg', '$day'::timestamptz, ('$day'::date + 1)::timestamptz)" < /dev/null >/dev/null
  done
  log "caggs refreshed: $day"
done

# ── gold + PO runtimes: only C rows whose GROSS/NET changed reach gold (scrap does not: line-lead derives it) —
# flag their hours/shifts/days, and NEVER older than 7 days (10-01 incident: re-flagging old shifts stalled the shift
# rollup for all tenants; past the engine windows the state-only pass rewrites old rows wrong).
G=$(P "WITH c AS (SELECT DISTINCT id_equipment, ts_value FROM $FIX
                   WHERE kind='unbacked' AND applied_at >= '$RUN_START' AND ts_value >= now() - interval '7 days'
                     AND (old_gross IS DISTINCT FROM new_gross OR old_net IS DISTINCT FROM new_net)),
            eqs AS (SELECT id_equipment FROM c
                    UNION SELECT e.id_equipment FROM core.equipments e JOIN c ON c.id_equipment IN (e.lead_machine, e.gross_machine, e.net_machine))
       , h AS (UPDATE gold.equipment_oee_hourly g SET recalc_needed = true FROM c
                WHERE g.id_equipment IN (SELECT id_equipment FROM eqs) AND g.ts_value = date_trunc('hour', c.ts_value) RETURNING 1)
       , s AS (UPDATE gold.equipment_oee_shift g SET recalc_needed = true FROM c
                WHERE g.id_equipment IN (SELECT id_equipment FROM eqs) AND c.ts_value >= g.ts_value AND c.ts_value < g.ts_end RETURNING 1)
       , d AS (UPDATE gold.equipment_oee_daily g SET recalc_needed = true FROM c
                WHERE g.id_equipment IN (SELECT id_equipment FROM eqs) AND g.ts_value = date_trunc('day', c.ts_value) RETURNING 1)
       , p AS (UPDATE gold.production_orders_runtime r SET recalc_needed = true FROM c
                WHERE r.id_equipment IN (SELECT id_equipment FROM eqs) AND r.runtime_timerange @> c.ts_value RETURNING 1)
       SELECT format('hour %s shift %s day %s po_runtime %s', (SELECT count(*) FROM h), (SELECT count(*) FROM s),
                     (SELECT count(*) FROM d), (SELECT count(*) FROM p))")
log "gold/PO flagged: $G"
log "done. verify: per line-day Σscrap = Σ(gross−net); no |incr| > $LIMIT; gold L6 10-06 gross ≈ members' corrected sum"
