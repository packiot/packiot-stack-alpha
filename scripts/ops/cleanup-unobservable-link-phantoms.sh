#!/usr/bin/env bash
# cleanup-unobservable-link-phantoms.sh — delete the OPEN phantom rows the CPAC deriver's PLC-link arms minted on
# machines it cannot observe (staging, 2026-10-09; user decision after S2_stale_open_stops).
# STAGING DATA ONLY: production is promoted from its own data (transplant), nothing here is replayed there.
#
# Until #1663 the link arms (LinkHealth, live since 10-01) minted a NO DATA (20) row at each PLC-link gap and a resume
# STOP (10) at the link's return for EVERY linked equipment — also for net-only, non-lead machines whose production the
# gross-only productive minute never sees. No RUNNING row can follow such a stop, so it stays open forever. #1663 limits
# the arms to OBSERVABLE equipment (the activity predicate saw it produce in the last 7 days); this script removes the
# open rows the fixed deriver would never have created. Bispharma downtime stays line-level (09-29 decision); the
# phantom rows CLOSED earlier (#1665, ops._fix_s2_stale_stops_20261009) are left as they are.
#
# A row is deleted only when ALL hold, re-checked per row right before its DELETE:
#   - enterprise in ENTS, status 5/10/11/20, ts_end IS NULL, ts_event older than 1 day;
#   - the equipment is mapped to a PLC endpoint (silver.plc_endpoint_equipment) — only link-aware equipment got arms;
#   - it is UNOBSERVABLE by the #1663 rule: no gross > 0 minute in the last 7 days, and, if it is the lead of a
#     downtime_from_lead_machine line, no net/scrap > 0 minute either;
#   - no human touched it (category/subcategory/machine/notes/planned/change-over/idle/forced creation).
# Every row is snapshotted whole into ops._fix_link_phantoms_20261009 first; deleted_at is set only from a read-back.
# Deletes are per row on a literal (id_equipment, ts_event) key with the status + still-open guards: no DELETE … USING,
# no stable bounds on the hypertable, never decompress_chunk.
# Then: gold (hour/shift/day + PO runtime) flagged only within the last 7 days, with literal bounds; serving
# .downtime_events_resolved refreshed from the oldest touched day, 3 days per call.
#
#   PSQL='docker exec -i timescaledb psql -U postgres -d packiot_analytics' ENTS=5 bash cleanup-unobservable-link-phantoms.sh
#   DRY_RUN=1 → snapshot + plan, then every DELETE + read-back inside ONE transaction that is ROLLED BACK.
# Undo (re-insert the snapshotted rows; an INSERT has no bound, so compressed chunks are fine):
#   <cols> = SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute
#            WHERE attrelid = 'silver.equipment_events'::regclass AND attnum > 0 AND NOT attisdropped;
#   INSERT INTO silver.equipment_events (<cols>) SELECT <cols> FROM ops._fix_link_phantoms_20261009 WHERE deleted_at IS NOT NULL
#     ON CONFLICT (id_equipment, ts_event) DO NOTHING;
set -euo pipefail
ENTS="${ENTS:?e.g. 5}"; DRY_RUN="${DRY_RUN:-0}"
PSQL="${PSQL:?psql command reaching packiot_analytics}"
P(){ $PSQL -X -v ON_ERROR_STOP=1 -At -c "SET statement_timeout='10min'; SET lock_timeout='10s'; $1" < /dev/null | tail -1; }
Q(){ $PSQL -X -v ON_ERROR_STOP=1 -At -F '|' -c "SET statement_timeout='10min'; $1" < /dev/null | sed 1d; }
log(){ echo "[$(date -u +%T)] $*"; }
FIX=ops._fix_link_phantoms_20261009
RUN_START=$(P "SELECT now()")

# unobservable(eq) by the #1663 rule — a SELECT predicate over the 1-min cagg (never used as a DML bound)
UNOBS="NOT EXISTS (SELECT 1 FROM silver.equipment_categorical_1min m
                    WHERE m.id_equipment = ev.id_equipment AND m.ts_value > now() - interval '7 days'
                      AND (m.gross_production_incr > 0
                           OR (ev.id_equipment IN (SELECT ln.lead_machine FROM core.equipments ln
                                                    WHERE ln.tp_equipment = 3 AND ln.downtime_from_lead_machine
                                                      AND coalesce(ln.lead_machine, 0) > 0)
                               AND (m.net_production_incr > 0 OR m.scrap_incr > 0))))"
HUMAN="(ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL OR ev.cd_machine IS NOT NULL
        OR ev.txt_downtime_notes IS NOT NULL OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE
        OR ev.idle IS NOT NULL OR ev.forced_creation_system IS TRUE)"

P "CREATE TABLE IF NOT EXISTS $FIX (LIKE silver.equipment_events)" >/dev/null
P "ALTER TABLE $FIX ADD COLUMN IF NOT EXISTS snapped_at timestamptz DEFAULT now(), ADD COLUMN IF NOT EXISTS deleted_at timestamptz" >/dev/null
P "CREATE UNIQUE INDEX IF NOT EXISTS _fix_link_phantoms_20261009_pk ON $FIX (id_equipment, ts_event)" >/dev/null

N=$(P "INSERT INTO $FIX
       SELECT ev.*, now(), NULL FROM silver.equipment_events ev
        WHERE ev.id_enterprise = ANY('{$ENTS}'::int[]) AND ev.ts_end IS NULL AND ev.status IN (5, 10, 11, 20)
          AND ev.ts_event < now() - interval '1 day'
          AND EXISTS (SELECT 1 FROM silver.plc_endpoint_equipment pe
                       WHERE pe.id_enterprise = ev.id_enterprise AND pe.id_equipment = ev.id_equipment)
          AND $UNOBS AND NOT $HUMAN
       ON CONFLICT (id_equipment, ts_event) DO NOTHING")
log "snapshot: $N new rows"
Q "SELECT 'plan', id_enterprise, status, count(*), min(ts_event), max(ts_event) FROM $FIX WHERE deleted_at IS NULL GROUP BY 2, 3 ORDER BY 2, 3" \
  | while read -r l; do log "  $l"; done

# per-row statement: delete only if the row is still the snapshotted open row AND the machine is still unobservable
stmt(){ # eq ts status
  echo "DELETE FROM silver.equipment_events WHERE id_equipment = $1 AND ts_event = '$2' AND status = $3 AND ts_end IS NULL;"
}
ROWS=$(Q "SELECT id_equipment, ts_event, status FROM $FIX f WHERE deleted_at IS NULL
           AND EXISTS (SELECT 1 FROM silver.equipment_events ev WHERE ev.id_equipment = f.id_equipment AND ev.ts_event = f.ts_event
                          AND ev.ts_end IS NULL AND ev.status = f.status AND $UNOBS AND NOT $HUMAN)
         ORDER BY 1, 2")
log "eligible now: $(grep -c . <<<"$ROWS" || true)"

if [ "$DRY_RUN" = 1 ]; then
  { echo "BEGIN;"
    while IFS='|' read -r eq ts st; do [ -n "$eq" ] && stmt "$eq" "$ts" "$st"; done <<<"$ROWS"
    echo "SELECT 'dry-readback-still-present', count(*) FROM $FIX f JOIN silver.equipment_events ev
            ON ev.id_equipment = f.id_equipment AND ev.ts_event = f.ts_event WHERE f.deleted_at IS NULL;"
    echo "ROLLBACK;"; } | $PSQL -X -v ON_ERROR_STOP=1 -At -f - | sort | uniq -c | while read -r l; do log "  dry: $l"; done
  log "dry run: rolled back, nothing changed"; exit 0
fi

while IFS='|' read -r eq ts st; do
  [ -n "$eq" ] || continue
  D=$(P "$(stmt "$eq" "$ts" "$st")")
  R=$(P "SELECT count(*) FROM silver.equipment_events WHERE id_equipment = $eq AND ts_event = '$ts'")
  if [ "$R" = 0 ]; then
    P "UPDATE $FIX SET deleted_at = now() WHERE id_equipment = $eq AND ts_event = '$ts'" >/dev/null
  else
    log "  NOT deleted: eq $eq $ts ($D, read-back $R)"
  fi
done <<<"$ROWS"
log "deleted: $(P "SELECT count(*) FROM $FIX WHERE deleted_at >= '$RUN_START'") rows this run"

# ── gold + PO runtimes, last 7 days only: an open row read as downtime/no-data from ts_event to now ─────────────
FLOOR=$(P "SELECT to_char(now() - interval '7 days', 'YYYY-MM-DD HH24:MI:SSOF')")
NOW=$(P "SELECT to_char(now(), 'YYYY-MM-DD HH24:MI:SSOF')")
mapfile -t SPANS < <(Q "WITH s AS (SELECT id_equipment, ts_event AS f FROM $FIX WHERE deleted_at >= '$RUN_START'),
                             x AS (SELECT id_equipment, f FROM s
                                   UNION SELECT l.id_equipment, s.f FROM s JOIN core.equipments l ON l.lead_machine = s.id_equipment AND l.tp_equipment = 3)
                        SELECT id_equipment, to_char(greatest(min(f), '$FLOOR'::timestamptz), 'YYYY-MM-DD HH24:MI:SSOF'),
                               to_char(date_trunc('hour', greatest(min(f), '$FLOOR'::timestamptz)), 'YYYY-MM-DD HH24:MI:SSOF'),
                               to_char(date_trunc('day', greatest(min(f), '$FLOOR'::timestamptz)) - interval '1 day', 'YYYY-MM-DD HH24:MI:SSOF')
                          FROM x GROUP BY 1 ORDER BY 1")
log "gold: ${#SPANS[@]} equipment spans to flag ([≥ $FLOOR, $NOW))"
for sp in "${SPANS[@]}"; do
  IFS='|' read -r eq f fh fd <<<"$sp"
  G=$(P "WITH h AS (UPDATE gold.equipment_oee_hourly SET recalc_needed = true
                     WHERE id_equipment = $eq AND ts_value >= '$fh' AND ts_value < '$NOW' AND recalc_needed IS NOT TRUE RETURNING 1),
              s AS (UPDATE gold.equipment_oee_shift SET recalc_needed = true
                     WHERE id_equipment = $eq AND ts_value < '$NOW' AND ts_end > '$f' AND ts_value >= '$fd' AND recalc_needed IS NOT TRUE RETURNING 1),
              d AS (UPDATE gold.equipment_oee_daily SET recalc_needed = true
                     WHERE id_equipment = $eq AND ts_value >= '$fd' AND ts_value < '$NOW' AND recalc_needed IS NOT TRUE RETURNING 1),
              p AS (UPDATE gold.production_orders_runtime SET recalc_needed = true
                     WHERE id_equipment = $eq AND runtime_timerange && tstzrange('$f', '$NOW') AND recalc_needed IS NOT TRUE RETURNING 1)
         SELECT format('h=%s s=%s d=%s po=%s', (SELECT count(*) FROM h), (SELECT count(*) FROM s), (SELECT count(*) FROM d), (SELECT count(*) FROM p))")
  log "  eq $eq [$f, now): $G"
done

# ── serving: re-derive from the oldest touched day, 3 days per call ───────────────────────────────────────────────
W=$(P "SELECT to_char(date_trunc('day', min(ts_event)), 'YYYY-MM-DD') FROM $FIX WHERE deleted_at >= '$RUN_START'")
if [ -n "$W" ]; then
  while [ "$(date -u -d "$W" +%s)" -lt "$(date -u +%s)" ]; do
    NX=$(date -u -d "$W + 3 days" +%F)
    P "SELECT serving.refresh_downtime_events_resolved('$W'::timestamptz, '$NX'::timestamptz)" >/dev/null
    W="$NX"
  done
  log "serving.downtime_events_resolved refreshed → now"
fi
log "done"
