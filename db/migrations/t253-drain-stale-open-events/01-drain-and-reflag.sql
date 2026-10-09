-- t253 — drain the stale-open-event backlog that drove the tp=3 line running_time
-- int-overflow (#253) + the silver-clamp net>gross/negative firing.
--
-- ROOT CAUSE: ~44k CPACK equipment_events left OPEN (ts_end IS NULL), oldest 2026-07-11.
-- compute.go Phase B sums status=6 event durations (open ⇒ now()) → production_orders_runtime.
-- running_time exploded 34–78× wall-clock (L5 PO27334: 40.9M over a 137,640s span). The
-- events-close-stale closer (closer.go) IS running but its 72h horizon orphaned the old
-- backlog (opens aged past 72h before the closer became effective in #187). This runs the
-- closer's OWN proven logic ONCE with a wide horizon to drain the backlog — NOT a clamp:
-- running_time becomes physically correct because the events are correctly closed
-- (non-latest ⇒ ts_end=next event ts [pure physics]; trailing ⇒ count-silence, human-edit
-- guarded). Dry-run proven: L5 PO27334 running_time 40.9M → 95,820 (≤ span); CPACK opens 12k → 22.
BEGIN;
SET LOCAL lock_timeout = '25s';
SET LOCAL timescaledb.max_tuples_decompressed_per_dml_transaction = 0;

WITH scope AS (
    SELECT e.id_equipment, COALESCE(NULLIF(e.stop_threshold_time,0), 300) AS thr
      FROM core.equipments e
     WHERE e.status_type = 0 AND e.tp_equipment IN (1,3) AND e.id_enterprise = ANY(ARRAY[3])
), lastcount AS (
    SELECT s.id_equipment, s.thr, max(m.ts_value) AS last_ts
      FROM scope s JOIN silver.equipment_categorical_1min m
        ON m.id_equipment=s.id_equipment AND m.ts_value > now()-make_interval(hours=>2000) AND m.gross_production_incr>0
     GROUP BY s.id_equipment, s.thr
), open_ev AS (
    SELECT ev.id_equipment_event, ev.id_equipment, ev.ts_event,
           lead(ev.ts_event) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_event, ev.id_equipment_event) AS next_ts
      FROM silver.equipment_events ev JOIN scope s ON s.id_equipment=ev.id_equipment
     WHERE ev.ts_event >= now()-make_interval(hours=>2000)
), plan AS (
    SELECT o.id_equipment_event,
           CASE WHEN o.next_ts IS NOT NULL THEN o.next_ts
                ELSE greatest(o.ts_event, lc.last_ts + make_interval(secs=>lc.thr)) END AS new_end,
           (o.next_ts IS NOT NULL) AS bounded_by_next
      FROM open_ev o LEFT JOIN lastcount lc ON lc.id_equipment=o.id_equipment
     WHERE o.next_ts IS NOT NULL OR (lc.last_ts IS NOT NULL AND lc.last_ts+make_interval(secs=>lc.thr) < now())
)
UPDATE silver.equipment_events ev
   SET ts_end=p.new_end, duration=extract(epoch FROM (p.new_end-ev.ts_event))::int, last_update=now()
  FROM plan p
 WHERE ev.id_equipment_event=p.id_equipment_event AND ev.ts_end IS NULL
   AND (p.bounded_by_next OR NOT (ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
        OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
        OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL));

-- Re-flag recent CPACK PO-runtime + OEE grains so the live rollup recomputes running_time
-- (now bounded by closed events) over the next passes → overflow clears, net>gross clamp quiets.
UPDATE gold.production_orders_runtime r SET recalc_needed = true
  FROM core.equipments e
 WHERE e.id_equipment = r.id_equipment AND e.id_enterprise = 3
   AND upper(r.runtime_timerange) > now() - interval '4 days';
COMMIT;
