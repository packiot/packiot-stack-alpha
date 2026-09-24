#!/usr/bin/env bash
# repair-truncated-stops.sh — undo the stale-event closer's STOP truncation (fixed in #1430).
# Until 2026-09-24 the closer's trailing count-silence close also closed OPEN STOPS, at (or
# ≤thr after) their own start, permanently. In a state stream an event lasts until the NEXT
# transition, so the canonical end of a truncated stop is the next event's ts_event.
#   1. snapshot the affected rows → ops._bkp_closer_stop_repair (id, old ts_end/duration)
#   2. set ts_end := next transition, week by week (guarded on the snapshotted ts_end)
#   3. refresh serving.downtime_events_resolved over the window, 3 days per call
# Run ON the DB box:  ENTS=3,5 FROM=2026-08-20 bash repair-truncated-stops.sh
# Undo: UPDATE silver.equipment_events e SET ts_end=b.ts_end_old, duration=b.duration_old
#       FROM ops._bkp_closer_stop_repair b WHERE e.id_equipment=b.id_equipment AND e.ts_event=b.ts_event;
set -euo pipefail
ENTS="${ENTS:?}"; FROM="${FROM:?}"
P(){ docker exec timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 -At -c "SET statement_timeout='10min'; $1" | tail -1; }
log(){ echo "[$(date -u +%T)] $*"; }
P "CREATE TABLE IF NOT EXISTS ops._bkp_closer_stop_repair (id_equipment int, ts_event timestamptz, id_equipment_event bigint,
     ts_end_old timestamptz, duration_old int, next_ts timestamptz, id_enterprise int, snapped_at timestamptz DEFAULT now(),
     PRIMARY KEY (id_equipment, ts_event))" >/dev/null
N=$(P "WITH ev AS (
         SELECT ev.id_equipment, ev.ts_event, ev.id_equipment_event, ev.ts_end, ev.duration, ev.status, ev.id_enterprise,
                lead(ev.ts_event) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_event, ev.id_equipment_event) AS next_ts
           FROM silver.equipment_events ev JOIN core.equipments e USING (id_equipment)
          WHERE ev.id_enterprise = ANY('{$ENTS}'::int[]) AND e.status_type = 0 AND e.tp_equipment IN (1,3)
            AND ev.ts_event >= '$FROM')
       INSERT INTO ops._bkp_closer_stop_repair (id_equipment, ts_event, id_equipment_event, ts_end_old, duration_old, next_ts, id_enterprise)
       SELECT id_equipment, ts_event, id_equipment_event, ts_end, duration, next_ts, id_enterprise FROM ev
        WHERE status = 10 AND next_ts IS NOT NULL AND ts_end IS NOT NULL AND ts_end < next_ts
       ON CONFLICT DO NOTHING")
log "snapshot: $N rows (ops._bkp_closer_stop_repair)"
W="$FROM"
while [ "$(date -u -d "$W" +%s)" -lt "$(date -u +%s)" ]; do
  NX=$(date -u -d "$W + 7 days" +%F)
  U=$(P "UPDATE silver.equipment_events e SET ts_end = b.next_ts,
            duration = extract(epoch FROM (b.next_ts - e.ts_event))::int, last_update = now()
          FROM ops._bkp_closer_stop_repair b
         WHERE e.id_equipment = b.id_equipment AND e.ts_event = b.ts_event
           AND e.ts_event >= '$W' AND e.ts_event < '$NX' AND b.ts_event >= '$W' AND b.ts_event < '$NX'
           AND e.status = 10 AND e.ts_end = b.ts_end_old")
  log "week $W: $U stops restored"
  W="$NX"
done
W="$FROM"
while [ "$(date -u -d "$W" +%s)" -lt "$(date -u +%s)" ]; do
  NX=$(date -u -d "$W + 3 days" +%F)
  P "SELECT serving.refresh_downtime_events_resolved('$W'::timestamptz, '$NX'::timestamptz)" >/dev/null
  W="$NX"
done
log "resolved view refreshed $FROM → now; DONE"
