#!/usr/bin/env bash
# backfill-lead-events.sh — one-off history backfill of the count-silence downtime events for
# NET-ONLY line leads (PR #1486). The live deriver (stream-engine cpac_deriver.go, LeadActivity)
# only recomputes the last 25h, so before its deploy those leads have NO events at all:
# Bispharma L18 (TAMPADEIRA) and BISNAGO L56/L57/L58/L60/L71/L72/L73 (M67x/M68x).
#
# Same model as the deriver: a productive minute = the lead's gross OR net OR scrap moved;
# a silence longer than stop_threshold_time (fallback THR) is a stop; RUNNING(6) at a
# session's first minute, STOPPED(10) at last minute + threshold. ONE DAY PER STATEMENT,
# oldest -> newest; each day reads thr+60s either side so sessions crossing midnight are
# not split (transitions outside the day are dropped; the neighbouring day mints them).
#
# SAFETY: dry-run by default (prints what each day WOULD insert). DEPLOY=1 inserts with
# ON CONFLICT (id_equipment, ts_event) DO NOTHING, never inside a human-protected span, never
# deletes a row, never edits a human-touched one. Stops at now()-25h (live deriver owns the rest).
# After the inserts: one re-chain pass (ts_end/duration = next event) over NON-human rows of
# these leads only, then serving.refresh_downtime_events_resolved.
# ORDER: deploy #1486 -> t-ent5-lead-event-display -> t-deriver-phantom-running-cleanup ->
#        THIS SCRIPT -> (it runs) refresh_downtime_events_resolved.
#
# Run ON the DB box:   ENT=5 FROM=2026-09-02 bash backfill-lead-events.sh           # dry run
#                      ENT=5 FROM=2026-09-02 DEPLOY=1 bash backfill-lead-events.sh  # execute
# LEADS=id,id,... overrides the default lead set (e.g. add L90's S2OUTPUT 2000330).
set -euo pipefail
ENT="${ENT:-5}"; FROM="${FROM:?FROM=YYYY-MM-DD}"; THR="${THR:-600}"; DEPLOY="${DEPLOY:-0}"
P(){ docker exec -i timescaledb psql -U postgres -d packiot_analytics -v ON_ERROR_STOP=1 -At -F '|' -c "SET statement_timeout='300s'; $1" | tail -n +2; }

# Default lead set: the lead_machine of every line whose downtime comes from the lead and that
# has NO gross_machine (the lead is its only meter).
if [ -z "${LEADS:-}" ]; then
  LEADS=$(P "SELECT string_agg(lead_machine::text, ',' ORDER BY lead_machine) FROM core.equipments
              WHERE id_enterprise=$ENT AND tp_equipment=3 AND downtime_from_lead_machine
                AND gross_machine IS NULL AND COALESCE(lead_machine,0) > 0")
fi
[ -n "$LEADS" ] || { echo "no leads to backfill"; exit 0; }
echo "$(date -u +%T) ent=$ENT leads=$LEADS from=$FROM thr_default=$THR deploy=$DEPLOY"

HUMAN_H="(h.forced_creation_system IS TRUE OR h.cd_category IS NOT NULL OR h.cd_subcategory IS NOT NULL
          OR h.cd_machine IS NOT NULL OR h.txt_downtime_notes IS NOT NULL
          OR h.planned_downtime IS TRUE OR h.change_over IS TRUE OR h.idle IS NOT NULL)"
HUMAN_EV="(ev.forced_creation_system IS TRUE OR ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
          OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
          OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL)"

# $1 = day (YYYY-MM-DD). Emits the per-day transitions CTE, ending in `f` (candidate rows).
day_cte(){ cat <<SQL
WITH scope AS (
    SELECT e.id_equipment, e.id_enterprise, COALESCE(NULLIF(e.stop_threshold_time, 0), $THR) AS thr
      FROM core.equipments e
     WHERE e.id_enterprise = $ENT AND e.status_type = 0 AND e.id_equipment IN ($LEADS)
), counts AS (
    SELECT s.id_equipment, s.id_enterprise, s.thr, m.ts_value AS ts,
           extract(epoch FROM (m.ts_value - lag(m.ts_value) OVER (PARTITION BY s.id_equipment ORDER BY m.ts_value))) AS gap
      FROM scope s
      JOIN silver.equipment_categorical_1min m ON m.id_equipment = s.id_equipment
       AND m.ts_value >  '$1'::timestamptz - make_interval(secs => s.thr + 60)
       AND m.ts_value <  '$1'::timestamptz + interval '1 day' + make_interval(secs => s.thr + 60)
       AND (m.gross_production_incr > 0 OR m.net_production_incr > 0 OR m.scrap_incr > 0)
), marked AS (
    SELECT *, sum(CASE WHEN gap IS NULL OR gap > thr THEN 1 ELSE 0 END) OVER (PARTITION BY id_equipment ORDER BY ts) AS sess
      FROM counts
), sessions AS (
    SELECT id_equipment, id_enterprise, thr, min(ts) AS run_start, max(ts) AS run_last
      FROM marked GROUP BY id_equipment, id_enterprise, thr, sess
), tr AS (
    SELECT id_equipment, id_enterprise, run_start AS ts_event, 6 AS status FROM sessions
    UNION ALL
    SELECT id_equipment, id_enterprise, run_last + make_interval(secs => thr), 10 FROM sessions
), f AS (
    SELECT tr.* FROM tr
     WHERE tr.ts_event >= '$1'::timestamptz
       AND tr.ts_event <  LEAST('$1'::timestamptz + interval '1 day', now() - interval '25 hours')
       AND NOT EXISTS (SELECT 1 FROM silver.equipment_events h
                        WHERE h.id_equipment = tr.id_equipment AND $HUMAN_H
                          AND tr.ts_event >= h.ts_event AND tr.ts_event < COALESCE(h.ts_end, now()))
       AND NOT EXISTS (SELECT 1 FROM silver.equipment_events x
                        WHERE x.id_equipment = tr.id_equipment AND x.ts_event = tr.ts_event)
)
SQL
}

LAST=$(P "SELECT (now() - interval '25 hours')::date")
d="$FROM"; TOTAL=0
while [[ "$d" < "$LAST" || "$d" == "$LAST" ]]; do
  if [ "$DEPLOY" = 1 ]; then
    N=$(P "$(day_cte "$d")
, ins AS (INSERT INTO silver.equipment_events (ts_event, id_equipment, status, id_enterprise, forced_creation_system)
          SELECT ts_event, id_equipment, status, id_enterprise, false FROM f
          ON CONFLICT (id_equipment, ts_event) DO NOTHING
          RETURNING 1)
SELECT count(*) FROM ins")
    echo "$(date -u +%T) $d inserted $N"
  else
    N=$(P "$(day_cte "$d") SELECT count(*) FROM f")
    echo "$(date -u +%T) $d would insert $N (dry run; stops=$(P "$(day_cte "$d") SELECT count(*) FROM f WHERE status=10"))"
  fi
  TOTAL=$((TOTAL + N)); d=$(date -u -d "$d + 1 day" +%F)
done
echo "$(date -u +%T) total rows: $TOTAL"
[ "$DEPLOY" = 1 ] || { echo "dry run only — re-run with DEPLOY=1 to insert"; exit 0; }

# Re-chain ts_end/duration of NON-human rows of these leads from FROM onwards (the next event,
# including the live deriver's rows after the backfilled range; open tail -> NULL).
P "WITH o AS (SELECT id_equipment, ts_event,
                     lead(ts_event) OVER (PARTITION BY id_equipment ORDER BY ts_event) AS nx
                FROM silver.equipment_events
               WHERE id_equipment IN ($LEADS) AND ts_event >= '$FROM'::timestamptz),
up AS (UPDATE silver.equipment_events ev
          SET ts_end = o.nx, duration = extract(epoch FROM (COALESCE(o.nx, now()) - ev.ts_event))::int
         FROM o
        WHERE ev.id_equipment = o.id_equipment AND ev.ts_event = o.ts_event
          AND ev.ts_event < now() - interval '25 hours'
          AND (ev.ts_end IS DISTINCT FROM o.nx OR ev.duration IS NULL)
          AND NOT $HUMAN_EV
       RETURNING 1)
SELECT count(*) FROM up" | sed "s/^/$(date -u +%T) re-chained rows: /"

P "SELECT serving.refresh_downtime_events_resolved('$FROM'::timestamptz, now())" | sed "s/^/$(date -u +%T) refresh_downtime_events_resolved rows: /"
echo "$(date -u +%T) DONE"
