-- t-downtime-resolved-unique — serving.downtime_events_resolved held DUPLICATE events (2026-10-01).
--
-- FOUND by the Bispharma + CPACK data audit: 10,270 extra rows on CPACK (ent 3, +~4,235 stop-hours
-- on the Downtimes pages / Pareto, 2023-02 → 2026-09-05), 10,104 on the twin, 153 on Bispharma.
-- Each pair is identical except resolved_at, ~1 s apart (09-29 22:39:03.9 vs :05.0): two
-- refresh_downtime_events_resolved calls on overlapping windows ran concurrently — each DELETEd
-- the window before the other INSERTed — and the table had no key to stop it. The source
-- (silver.equipment_events) is correct; only the serving copy was inflated.
-- FIX: 1. dedupe, keeping the newest resolved_at per (id_enterprise, manual_event, id_equipment_event)
--         (manual and base events have separate id sequences: 619 ids are shared, legitimately;
--         the twin reuses CPACK's ids, so the key needs id_enterprise);
--      2. UNIQUE index on that key;
--      3. the refresh takes a transaction advisory lock (runs queue, never interleave), selects ONE
--         row per event (DISTINCT ON — the shift join can match two overlapping shift rows) and
--         upserts (a re-run, or an event whose start moved out of the window, overwrites).
SET lock_timeout = '30s';
BEGIN;
LOCK TABLE serving.downtime_events_resolved IN SHARE ROW EXCLUSIVE MODE;   -- writers wait; readers don't
DELETE FROM serving.downtime_events_resolved r
 USING (SELECT ctid, row_number() OVER (PARTITION BY id_enterprise, manual_event, id_equipment_event
                                         ORDER BY resolved_at DESC NULLS LAST, ctid DESC) AS rn
          FROM serving.downtime_events_resolved) d
 WHERE r.ctid = d.ctid AND d.rn > 1;
CREATE UNIQUE INDEX IF NOT EXISTS dt_events_resolved_event_uk
    ON serving.downtime_events_resolved (id_enterprise, manual_event, id_equipment_event);
CREATE OR REPLACE FUNCTION serving.refresh_downtime_events_resolved(_from timestamp with time zone, _to timestamp with time zone)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE n bigint;
BEGIN
    -- one refresh at a time: two overlapping runs each deleted before the other inserted → every
    -- event twice (10,270 CPACK / 10,104 twin / 153 Bispharma extra rows, t-downtime-resolved-unique)
    PERFORM pg_advisory_xact_lock(hashtextextended('serving.refresh_downtime_events_resolved', 0));
    DELETE FROM serving.downtime_events_resolved WHERE ts_event >= _from AND ts_event < _to;

    INSERT INTO serving.downtime_events_resolved (
        id_equipment_event, manual_event, id_equipment, id_sector, id_line, nm_equipment, sector,
        id_area, id_site, id_parentequipment, cd_machine, duration, cd_category, txt_category,
        cd_subcategory, txt_subcategory, txt_downtime_notes, timezone, day_begin, stop_threshold_time,
        planned_downtime, change_over, shift_ts_range, id_order, cd_shift, id_shift, id_enterprise, ts_event, ts_end)
    SELECT DISTINCT ON (ee.id_enterprise, ee.id_equipment_event) ee.id_equipment_event, false, ee.id_equipment,
        case when eq.tp_equipment=2 then eq.id_equipment when peq.tp_equipment=2 then peq.id_equipment when ppeq.tp_equipment=2 then ppeq.id_equipment else null end,
        coalesce(ppeq.id_equipment, peq.id_equipment, eq.id_equipment),
        case when eq.tp_equipment=3 then eq.nm_equipment when peq.tp_equipment=3 then peq.nm_equipment when ppeq.tp_equipment=3 then ppeq.nm_equipment else null end,
        case when eq.tp_equipment=2 then eq.nm_equipment when peq.tp_equipment=2 then peq.nm_equipment when ppeq.tp_equipment=2 then ppeq.nm_equipment else null end,
        eq.id_area, eq.id_site, eq.id_parentequipment, ee.cd_machine, ee.duration, ee.cd_category,
        ee.desc_category, ee.cd_subcategory, ee.desc_subcategory, ee.txt_downtime_notes, st.timezone,
        st.day_begin, eq.stop_threshold_time, ee.planned_downtime, ee.change_over, ers.ts_range,
        (select id_order from production_orders po where po.id_production_order =
            (select id_production_order from production_orders_runtime por
             where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce(ppeq.id_equipment, peq.id_equipment, eq.id_equipment))),
        sh.cd_shift, ers.id_shift, ee.id_enterprise, ee.ts_event, ee.ts_end
    FROM equipment_events ee
        left join equipments eq  on eq.id_equipment  = ee.id_equipment
        left join sites st       on eq.id_site       = st.id_site
        left join equipment_oee_shift ers on ee.ts_event <@ ers.ts_range and ers.id_equipment = ee.id_equipment
        left join shifts sh      on ers.id_shift     = sh.id_shift
        left join equipments peq  on peq.id_equipment  = eq.id_parentequipment
        left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
    WHERE ee.status <> 6 AND eq.event_should_be_displayed = true
      AND ee.ts_event >= _from AND ee.ts_event < _to
    ORDER BY ee.id_enterprise, ee.id_equipment_event, upper(ers.ts_range) DESC NULLS LAST
    ON CONFLICT (id_enterprise, manual_event, id_equipment_event) DO UPDATE SET id_equipment = EXCLUDED.id_equipment, id_sector = EXCLUDED.id_sector, id_line = EXCLUDED.id_line, nm_equipment = EXCLUDED.nm_equipment, sector = EXCLUDED.sector, id_area = EXCLUDED.id_area, id_site = EXCLUDED.id_site, id_parentequipment = EXCLUDED.id_parentequipment, cd_machine = EXCLUDED.cd_machine, duration = EXCLUDED.duration, cd_category = EXCLUDED.cd_category, txt_category = EXCLUDED.txt_category, cd_subcategory = EXCLUDED.cd_subcategory, txt_subcategory = EXCLUDED.txt_subcategory, txt_downtime_notes = EXCLUDED.txt_downtime_notes, timezone = EXCLUDED.timezone, day_begin = EXCLUDED.day_begin, stop_threshold_time = EXCLUDED.stop_threshold_time, planned_downtime = EXCLUDED.planned_downtime, change_over = EXCLUDED.change_over, shift_ts_range = EXCLUDED.shift_ts_range, id_order = EXCLUDED.id_order, cd_shift = EXCLUDED.cd_shift, id_shift = EXCLUDED.id_shift, ts_event = EXCLUDED.ts_event, ts_end = EXCLUDED.ts_end, resolved_at = now();
    GET DIAGNOSTICS n = ROW_COUNT;

    INSERT INTO serving.downtime_events_resolved (
        id_equipment_event, manual_event, id_equipment, id_sector, id_line, nm_equipment, sector,
        id_area, id_site, id_parentequipment, cd_machine, duration, cd_category, txt_category,
        cd_subcategory, txt_subcategory, txt_downtime_notes, timezone, day_begin, stop_threshold_time,
        planned_downtime, change_over, shift_ts_range, id_order, cd_shift, id_shift, id_enterprise, ts_event, ts_end)
    SELECT DISTINCT ON (ee.id_enterprise, ee.id_equipment_event) ee.id_equipment_event, true, ee.id_equipment,
        case when eq.tp_equipment=2 then eq.id_equipment when peq.tp_equipment=2 then peq.id_equipment when ppeq.tp_equipment=2 then ppeq.id_equipment else null end,
        coalesce(ppeq.id_equipment, peq.id_equipment, eq.id_equipment),
        case when eq.tp_equipment=3 then eq.nm_equipment when peq.tp_equipment=3 then peq.nm_equipment when ppeq.tp_equipment=3 then ppeq.nm_equipment else null end,
        case when eq.tp_equipment=2 then eq.nm_equipment when peq.tp_equipment=2 then peq.nm_equipment when ppeq.tp_equipment=2 then ppeq.nm_equipment else null end,
        eq.id_area, eq.id_site, eq.id_parentequipment, ee.cd_machine, ee.duration, ee.cd_category,
        ee.desc_category, ee.cd_subcategory, ee.desc_subcategory, ee.txt_downtime_notes, st.timezone,
        st.day_begin, eq.stop_threshold_time, ee.planned_downtime, ee.change_over, ers.ts_range,
        (select id_order from production_orders po where po.id_production_order =
            (select id_production_order from production_orders_runtime por
             where ee.ts_event <@ por.runtime_timerange and id_equipment = coalesce(ppeq.id_equipment, peq.id_equipment, ee.id_equipment))),
        sh.cd_shift, ers.id_shift, ee.id_enterprise, ee.ts_event, ee.ts_end
    FROM equipment_events_man ee
        left join equipments eq  on eq.id_equipment  = ee.id_equipment
        left join sites st       on eq.id_site       = st.id_site
        left join equipment_oee_shift ers on ee.ts_event <@ ers.ts_range and ers.id_equipment = ee.id_equipment
        left join shifts sh      on ers.id_shift     = sh.id_shift
        left join equipments peq  on peq.id_equipment  = eq.id_parentequipment
        left join equipments ppeq on ppeq.id_equipment = peq.id_parentequipment
    WHERE eq.event_should_be_displayed = true
      AND ee.ts_event >= _from AND ee.ts_event < _to
    ORDER BY ee.id_enterprise, ee.id_equipment_event, upper(ers.ts_range) DESC NULLS LAST
    ON CONFLICT (id_enterprise, manual_event, id_equipment_event) DO UPDATE SET id_equipment = EXCLUDED.id_equipment, id_sector = EXCLUDED.id_sector, id_line = EXCLUDED.id_line, nm_equipment = EXCLUDED.nm_equipment, sector = EXCLUDED.sector, id_area = EXCLUDED.id_area, id_site = EXCLUDED.id_site, id_parentequipment = EXCLUDED.id_parentequipment, cd_machine = EXCLUDED.cd_machine, duration = EXCLUDED.duration, cd_category = EXCLUDED.cd_category, txt_category = EXCLUDED.txt_category, cd_subcategory = EXCLUDED.cd_subcategory, txt_subcategory = EXCLUDED.txt_subcategory, txt_downtime_notes = EXCLUDED.txt_downtime_notes, timezone = EXCLUDED.timezone, day_begin = EXCLUDED.day_begin, stop_threshold_time = EXCLUDED.stop_threshold_time, planned_downtime = EXCLUDED.planned_downtime, change_over = EXCLUDED.change_over, shift_ts_range = EXCLUDED.shift_ts_range, id_order = EXCLUDED.id_order, cd_shift = EXCLUDED.cd_shift, id_shift = EXCLUDED.id_shift, ts_event = EXCLUDED.ts_event, ts_end = EXCLUDED.ts_end, resolved_at = now();
    RETURN n;
END $function$;
COMMIT;
