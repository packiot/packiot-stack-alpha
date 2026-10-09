#!/usr/bin/env bash
# repair-s2-stale-open-stops.sh — staging data repair for invariant S2_stale_open_stops (2026-10-09).
# STAGING DATA ONLY: production is promoted from its own data (transplant), nothing here is replayed there.
#
# Two causes, two closes (diagnosis in the PRs for the code fixes):
#   successor        CPACK ent 3 + sandbox 2000003: the twin missed every legacy base event after 2026-10-07 14:13 (the
#                    edge moved to Pub/Sub; the replicator only copied events announced in user_logs). Once the base-event
#                    reconciler has backfilled them, each stale stop HAS a successor and ends there — the closer's own
#                    rule ("a stop lasts until the next transition"), applied here with literal bounds because the
#                    closer's long-open pass is an UPDATE … FROM, which matches 0 rows on compressed chunks.
#   first_production Bispharma ent 5 (PHANTOM_ENTS): the deriver's PLC-link arms minted a resume STOP on net-only machines
#                    it cannot observe, so no successor will ever come. Such a stop ends at the machine's first productive
#                    minute (gross or net moved) after it — never when a human justified the row, never without production.
#   Any other stale stop without a successor is reported and LEFT OPEN (a stop with no successor is the truth until
#   evidence says otherwise; legacy itself kept CER400 stopped for 6 days through counted output).
#
# Then: gold flags (hour/shift/day + PO runtimes) only within the last 7 days — for every closed stop's span and, for
# BACKFILL_ENTS, for every equipment over [BACKFILL_FROM, now) (the reconciler inserted events into already-computed
# hours) — and serving.downtime_events_resolved refreshed from the oldest touched day, 3 days per call.
#
# Every changed row is snapshotted first in ops._fix_s2_stale_stops_20261009 (old + new values); applied_at is set only
# from a read-back. Updates are per row with a literal (id_equipment, ts_event) key and `ts_end IS NULL` guard: no
# UPDATE … FROM, no stable bounds, never decompress_chunk.
#
#   PSQL='docker exec -i timescaledb psql -U postgres -d packiot_analytics' \
#   ENTS=3,5,2000003 PHANTOM_ENTS=5 BACKFILL_ENTS=3,2000003 BACKFILL_FROM='2026-10-07 14:00+00' bash repair-s2-stale-open-stops.sh
#   DRY_RUN=1 → snapshot + report only (the snapshot rows stay unapplied and are refreshed on the next run).
# Undo (per row; literal keys from the snapshot):
#   UPDATE silver.equipment_events SET ts_end = NULL, duration = f.old_duration FROM … — or, compressed-chunk safe:
#   SELECT format('UPDATE silver.equipment_events SET ts_end = NULL, duration = %s WHERE id_equipment = %s AND ts_event = %L;',
#                 coalesce(old_duration::text, 'NULL'), id_equipment, ts_event) FROM ops._fix_s2_stale_stops_20261009 WHERE applied_at IS NOT NULL;
set -euo pipefail
ENTS="${ENTS:?e.g. 3,5,2000003}"; PHANTOM_ENTS="${PHANTOM_ENTS:-0}"; BACKFILL_ENTS="${BACKFILL_ENTS:-0}"
BACKFILL_FROM="${BACKFILL_FROM:-}"; DRY_RUN="${DRY_RUN:-0}"
PSQL="${PSQL:?psql command reaching packiot_analytics}"
P(){ $PSQL -X -v ON_ERROR_STOP=1 -At -c "SET statement_timeout='10min'; SET lock_timeout='10s'; $1" < /dev/null | tail -1; }
Q(){ $PSQL -X -v ON_ERROR_STOP=1 -At -F '|' -c "SET statement_timeout='10min'; $1" < /dev/null | sed 1d; }
log(){ echo "[$(date -u +%T)] $*"; }
FIX=ops._fix_s2_stale_stops_20261009
RUN_START=$(P "SELECT now()")

P "CREATE TABLE IF NOT EXISTS $FIX (
     id_enterprise int, id_equipment int, ts_event timestamptz, status int,
     old_ts_end timestamptz, old_duration int, new_ts_end timestamptz, basis text,
     snapped_at timestamptz DEFAULT now(), applied_at timestamptz,
     PRIMARY KEY (id_equipment, ts_event))" >/dev/null

# ── snapshot: every open stop older than a day (the S2 population, all tenants in ENTS) with its proposed end ──────
# successor = the equipment's next event; first_production only for PHANTOM_ENTS, only without a successor, only when
# no human touched the row, and only when the machine produced again (else it stays open).
N=$(P "INSERT INTO $FIX (id_enterprise, id_equipment, ts_event, status, old_ts_end, old_duration, new_ts_end, basis)
       SELECT ev.id_enterprise, ev.id_equipment, ev.ts_event, ev.status, ev.ts_end, ev.duration,
              coalesce(nx.ts, fp.ts), CASE WHEN nx.ts IS NOT NULL THEN 'successor' ELSE 'first_production' END
         FROM silver.equipment_events ev
         LEFT JOIN LATERAL (SELECT n.ts_event AS ts FROM silver.equipment_events n
                             WHERE n.id_equipment = ev.id_equipment AND n.ts_event > ev.ts_event
                             ORDER BY n.ts_event LIMIT 1) nx ON true
         LEFT JOIN LATERAL (SELECT m.ts_value AS ts FROM silver.equipment_categorical_1min m
                             WHERE m.id_equipment = ev.id_equipment AND m.ts_value > ev.ts_event
                               AND (m.gross_production_incr > 0 OR m.net_production_incr > 0)
                             ORDER BY m.ts_value LIMIT 1) fp
                ON ev.id_enterprise = ANY('{$PHANTOM_ENTS}'::int[])
               AND NOT (ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL OR ev.cd_machine IS NOT NULL
                        OR ev.txt_downtime_notes IS NOT NULL OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE
                        OR ev.idle IS NOT NULL)
        WHERE ev.id_enterprise = ANY('{$ENTS}'::int[]) AND ev.ts_end IS NULL AND ev.status IN (5, 10, 11)
          AND ev.ts_event < now() - interval '1 day' AND ev.ts_event > now() - interval '90 days'
          AND coalesce(nx.ts, fp.ts) IS NOT NULL
       ON CONFLICT (id_equipment, ts_event) DO UPDATE
         SET old_ts_end = EXCLUDED.old_ts_end, old_duration = EXCLUDED.old_duration, new_ts_end = EXCLUDED.new_ts_end,
             basis = EXCLUDED.basis, snapped_at = now()
         WHERE $FIX.applied_at IS NULL")
log "snapshot: $N stale stops with an evidence-based end"
Q "SELECT 'plan', id_enterprise, basis, count(*), min(ts_event), max(ts_event) FROM $FIX WHERE applied_at IS NULL GROUP BY 2, 3 ORDER BY 2, 3" \
  | while read -r l; do log "  $l"; done
Q "SELECT 'left-open', ev.id_enterprise, ev.id_equipment, ev.ts_event FROM silver.equipment_events ev
    WHERE ev.id_enterprise = ANY('{$ENTS}'::int[]) AND ev.ts_end IS NULL AND ev.status IN (5, 10, 11)
      AND ev.ts_event < now() - interval '1 day' AND ev.ts_event > now() - interval '90 days'
      AND NOT EXISTS (SELECT 1 FROM $FIX f WHERE f.id_equipment = ev.id_equipment AND f.ts_event = ev.ts_event)
    ORDER BY 2, 3" | while read -r l; do log "  $l"; done
if [ "$DRY_RUN" = 1 ]; then log "dry run: nothing changed"; exit 0; fi

# ── apply: one row per statement, literal key, guarded on the row still being open ───────────────────────────────
while IFS='|' read -r eq ts end; do
  [ -n "$eq" ] || continue
  U=$(P "UPDATE silver.equipment_events SET ts_end = '$end', duration = extract(epoch FROM ('$end'::timestamptz - '$ts'::timestamptz))::int,
            last_update = now()
          WHERE id_equipment = $eq AND ts_event = '$ts' AND ts_end IS NULL")
  R=$(P "SELECT ts_end = '$end'::timestamptz FROM silver.equipment_events WHERE id_equipment = $eq AND ts_event = '$ts'")
  if [ "$R" = t ]; then
    P "UPDATE $FIX SET applied_at = now() WHERE id_equipment = $eq AND ts_event = '$ts'" >/dev/null
  else
    log "  NOT applied: eq $eq $ts → $end ($U, read-back '$R')"
  fi
done < <(Q "SELECT id_equipment, ts_event, new_ts_end FROM $FIX WHERE applied_at IS NULL ORDER BY id_equipment, ts_event")
log "applied: $(P "SELECT count(*) FROM $FIX WHERE applied_at >= '$RUN_START'") rows this run"

# ── gold + PO runtimes, last 7 days only (10-01 incident) ─────────────────────────────────────────────────────────
# spans: each closed stop [ts_event, new_ts_end) and, for BACKFILL_ENTS, every equipment over [BACKFILL_FROM, now).
# Bounds (incl. the hour/day floors) are computed into literals first; the flag UPDATEs are per equipment with literal
# ts bounds only (a stable expression bound silently matches 0 rows on a compressed chunk).
FLOOR=$(P "SELECT to_char(now() - interval '7 days', 'YYYY-MM-DD HH24:MI:SSOF')")
NOW=$(P "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SSOF')")
BF=""
[ -n "$BACKFILL_FROM" ] && BF="UNION ALL SELECT e.id_equipment, '$BACKFILL_FROM'::timestamptz, '$NOW'::timestamptz
                                 FROM core.equipments e WHERE e.id_enterprise = ANY('{$BACKFILL_ENTS}'::int[])"
mapfile -t SPANS < <(Q "WITH s AS (SELECT id_equipment, ts_event AS f, new_ts_end AS t FROM $FIX WHERE applied_at >= '$RUN_START' $BF),
                             x AS (SELECT id_equipment, f, t FROM s
                                   UNION SELECT l.id_equipment, s.f, s.t FROM s JOIN core.equipments l ON l.lead_machine = s.id_equipment AND l.tp_equipment = 3)
                        SELECT id_equipment, to_char(greatest(min(f), '$FLOOR'::timestamptz), 'YYYY-MM-DD HH24:MI:SSOF'),
                               to_char(max(t), 'YYYY-MM-DD HH24:MI:SSOF'),
                               to_char(date_trunc('hour', greatest(min(f), '$FLOOR'::timestamptz)), 'YYYY-MM-DD HH24:MI:SSOF'),
                               to_char(date_trunc('day', greatest(min(f), '$FLOOR'::timestamptz)) - interval '1 day', 'YYYY-MM-DD HH24:MI:SSOF')
                          FROM x GROUP BY 1 HAVING max(t) > '$FLOOR'::timestamptz ORDER BY 1")
log "gold: ${#SPANS[@]} equipment spans to flag (≥ $FLOOR)"
for sp in "${SPANS[@]}"; do
  IFS='|' read -r eq f t fh fd <<<"$sp"
  G=$(P "WITH h AS (UPDATE gold.equipment_oee_hourly SET recalc_needed = true
                     WHERE id_equipment = $eq AND ts_value >= '$fh' AND ts_value < '$t'
                       AND recalc_needed IS NOT TRUE RETURNING 1),
              s AS (UPDATE gold.equipment_oee_shift SET recalc_needed = true
                     WHERE id_equipment = $eq AND ts_value < '$t' AND ts_end > '$f' AND ts_value >= '$fd'
                       AND recalc_needed IS NOT TRUE RETURNING 1),
              d AS (UPDATE gold.equipment_oee_daily SET recalc_needed = true
                     WHERE id_equipment = $eq AND ts_value >= '$fd' AND ts_value < '$t'
                       AND recalc_needed IS NOT TRUE RETURNING 1),
              p AS (UPDATE gold.production_orders_runtime SET recalc_needed = true
                     WHERE id_equipment = $eq AND runtime_timerange && tstzrange('$f', '$t') AND recalc_needed IS NOT TRUE RETURNING 1)
         SELECT format('h=%s s=%s d=%s po=%s', (SELECT count(*) FROM h), (SELECT count(*) FROM s), (SELECT count(*) FROM d), (SELECT count(*) FROM p))")
  log "  eq $eq [$f, $t): $G"
done

# ── serving: re-derive the resolved downtime rows from the oldest touched day, 3 days per call ─────────────────────
W=$(P "SELECT to_char(date_trunc('day', least(min(ts_event), coalesce(nullif('$BACKFILL_FROM', '')::timestamptz, 'infinity'))), 'YYYY-MM-DD')
         FROM $FIX WHERE applied_at >= '$RUN_START'")
if [ -n "$W" ]; then
  while [ "$(date -u -d "$W" +%s)" -lt "$(date -u +%s)" ]; do
    NX=$(date -u -d "$W + 3 days" +%F)
    P "SELECT serving.refresh_downtime_events_resolved('$W'::timestamptz, '$NX'::timestamptz)" >/dev/null
    W="$NX"
  done
  log "serving.downtime_events_resolved refreshed → now"
fi
log "done. verify: S2 query read-only (0 rows for ENTS) and the left-open list above"
