-- t-downtime-events-materialization — precomputed downtime-events serving table.
--
-- WHY: serving.downtime_events_v2 is ~300ms warm but ~18-40s COLD (it decompresses ~2 months of
-- silver.equipment_events chunks per request + does a per-candidate correlated production_orders_runtime
-- lookup + an equipment_oee_shift range join). read-api caps /v1/query, so the front4 Downtimes page's
-- default month-to-date events leg 500'd on open. A timeout bump can't fix I/O-bound cold random reads.
--
-- FIX: materialize the per-event resolution (the expensive part) into serving.downtime_events_resolved,
-- refreshed incrementally every 2 min by a TimescaleDB job. serving.downtime_events_v3 is a thin reader
-- over it that applies v2's EXACT read-time predicates (tz conversion / ±1mo pad / overlap / microstop
-- rule / id filters) + DISTINCT (matches v2's UNION) + a coverage-fallback to v2 for windows older than
-- the backfill. The resolution SQL below is lifted VERBATIM from v2's inner `aa` (both branches) minus the
-- window/microstop filters (which move to read time) — so rows are identical by construction. Gated on
-- exact set-parity vs v2 (v2 EXCEPT v3 = v3 EXCEPT v2 = 0) across 24h/3d/7d/month windows, both microstop
-- modes, 2 tenants. read-api downtimes-events dataset repointed v2 -> v3 (revertible one-liner).
--
-- APPLY ORDER: this migration MUST be applied before a read-api build that points downtimes-events at v3
-- (else the dataset's SELECT ... downtime_events_v3 errors on a DB without it). Idempotent + non-destructive
-- (IF NOT EXISTS table + guarded one-time backfill) so re-applying never wipes the populated table.

CREATE TABLE IF NOT EXISTS serving.downtime_events_resolved (
    id_equipment_event bigint not null, manual_event boolean not null,
    id_equipment int, id_sector int, id_line int, nm_equipment varchar, sector varchar,
    id_area int, id_site int, id_parentequipment int, cd_machine varchar, duration int,
    cd_category varchar, txt_category varchar, cd_subcategory varchar, txt_subcategory varchar,
    txt_downtime_notes varchar, timezone text, day_begin int, stop_threshold_time int,
    planned_downtime boolean, change_over boolean, shift_ts_range tstzrange, id_order int,
    cd_shift varchar, id_shift int, id_enterprise int,
    ts_event timestamptz not null, ts_end timestamptz, resolved_at timestamptz not null default now()
);
CREATE INDEX IF NOT EXISTS dt_events_resolved_ent_ts   ON serving.downtime_events_resolved (id_enterprise, ts_event desc);
CREATE INDEX IF NOT EXISTS dt_events_resolved_ent_line ON serving.downtime_events_resolved (id_enterprise, id_line, ts_event desc);
CREATE INDEX IF NOT EXISTS dt_events_resolved_tsev     ON serving.downtime_events_resolved (ts_event);

CREATE TABLE IF NOT EXISTS serving.downtime_events_resolved_meta (
    id int primary key default 1, coverage_from timestamptz, check (id = 1));
INSERT INTO serving.downtime_events_resolved_meta (id, coverage_from) VALUES (1, NULL) ON CONFLICT (id) DO NOTHING;

-- ── refresh: DELETE the [_from,_to) ts_event range then re-INSERT it (idempotent, preserves v2's
--    multi-row-per-event UNION behaviour from overlapping oee_shift matches). ────────────────────────
CREATE OR REPLACE FUNCTION serving.refresh_downtime_events_resolved(_from timestamptz, _to timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE n bigint;
BEGIN
    DELETE FROM serving.downtime_events_resolved WHERE ts_event >= _from AND ts_event < _to;

    INSERT INTO serving.downtime_events_resolved (
        id_equipment_event, manual_event, id_equipment, id_sector, id_line, nm_equipment, sector,
        id_area, id_site, id_parentequipment, cd_machine, duration, cd_category, txt_category,
        cd_subcategory, txt_subcategory, txt_downtime_notes, timezone, day_begin, stop_threshold_time,
        planned_downtime, change_over, shift_ts_range, id_order, cd_shift, id_shift, id_enterprise, ts_event, ts_end)
    SELECT ee.id_equipment_event, false, ee.id_equipment,
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
      AND ee.ts_event >= _from AND ee.ts_event < _to;
    GET DIAGNOSTICS n = ROW_COUNT;

    INSERT INTO serving.downtime_events_resolved (
        id_equipment_event, manual_event, id_equipment, id_sector, id_line, nm_equipment, sector,
        id_area, id_site, id_parentequipment, cd_machine, duration, cd_category, txt_category,
        cd_subcategory, txt_subcategory, txt_downtime_notes, timezone, day_begin, stop_threshold_time,
        planned_downtime, change_over, shift_ts_range, id_order, cd_shift, id_shift, id_enterprise, ts_event, ts_end)
    SELECT ee.id_equipment_event, true, ee.id_equipment,
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
      AND ee.ts_event >= _from AND ee.ts_event < _to;
    RETURN n;
END $fn$;

-- ── reader (same signature + RETURNS as v2). ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION serving.downtime_events_v3(
    in_id_enterprise integer, in_ids_sites text, in_ids_areas text, in_ids_equipments text, in_ids_sectors text,
    _tsstart timestamp without time zone DEFAULT date_trunc('month'::text, now()),
    _tsend timestamp without time zone DEFAULT now(), microstops_view boolean DEFAULT false)
RETURNS SETOF downtime_events_v2_row LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    ids_sites   int[] := (select array_agg(id_site)      from sites s      where s.id_enterprise=in_id_enterprise and case when cardinality(in_ids_sites::int[])=0 then true else id_site=any(in_ids_sites::int[]) end);
    ids_areas   int[] := (select array_agg(id_area)      from areas s      where s.id_enterprise=in_id_enterprise and case when cardinality(in_ids_areas::int[])=0 then true else id_area=any(in_ids_areas::int[]) end);
    ids_equips  int[] := (select array_agg(id_equipment) from equipments s where s.id_enterprise=in_id_enterprise and s.tp_equipment=3 and case when cardinality(in_ids_equipments::int[])=0 then true else id_equipment=any(in_ids_equipments::int[]) end);
    ids_sectors int[] := (select array_agg(id_equipment) from equipments s where s.id_enterprise=in_id_enterprise and s.tp_equipment=2 and case when cardinality(in_ids_sectors::int[])=0 then true else id_equipment=any(in_ids_sectors::int[]) end);
    cov timestamptz;
BEGIN
    SELECT coverage_from INTO cov FROM serving.downtime_events_resolved_meta WHERE id=1;
    IF cov IS NULL OR (_tsstart::timestamp - interval '1 month') < cov THEN
        RETURN QUERY SELECT * FROM serving.downtime_events_v2(in_id_enterprise, in_ids_sites, in_ids_areas, in_ids_equipments, in_ids_sectors, _tsstart, _tsend, microstops_view);
        RETURN;
    END IF;
    RETURN QUERY
    SELECT DISTINCT
        r.id_equipment_event, (r.ts_event at time zone (r.timezone))::timestamp, (r.ts_end at time zone (r.timezone))::timestamp,
        r.id_equipment, r.id_sector, r.nm_equipment, r.sector, r.cd_machine, r.duration, r.cd_category,
        r.txt_category, r.cd_subcategory, r.txt_subcategory, r.txt_downtime_notes, r.id_order, r.cd_shift,
        r.id_shift, r.id_enterprise, r.planned_downtime, r.change_over, r.shift_ts_range, r.stop_threshold_time, r.manual_event
    FROM serving.downtime_events_resolved r
    WHERE r.id_enterprise = in_id_enterprise
      AND r.ts_event > _tsstart::timestamp - interval '1 month'
      AND ((r.ts_end < _tsend::timestamp + interval '1 month') OR (r.ts_end IS NULL AND r.manual_event = false))
      AND tstzrange(r.ts_event::timestamp, r.ts_end::timestamp, '[)')
          && tstzrange((_tsstart at time zone (r.timezone))::timestamp + interval '1 second' * r.day_begin,
                       (_tsend   at time zone (r.timezone))::timestamp + interval '1 second' * r.day_begin, '[)')
      AND ((not microstops_view and (r.duration >= COALESCE(r.stop_threshold_time,0) or r.duration is null))
           or microstops_view or (r.cd_category is not null and (r.manual_event = false or r.cd_category <> '')))
      AND r.id_site = any(ids_sites) AND r.id_area = any(ids_areas) AND r.id_line = any(ids_equips)
      AND ((ids_sectors is null) or (r.id_sector = any(ids_sectors) and r.id_site = any(ids_sites) and r.id_area = any(ids_areas)) or (r.id_sector is null))
    ORDER BY 2 DESC;
END $fn$;

-- ── incremental refresh job (TimescaleDB scheduler; pg_cron is not installed on this DB). ──────────
CREATE OR REPLACE PROCEDURE serving.job_refresh_downtime_events_resolved(job_id int, config jsonb)
LANGUAGE plpgsql AS $$ BEGIN PERFORM serving.refresh_downtime_events_resolved(now()-interval '3 days', now()); END $$;

-- one-time backfill + coverage + schedule, only on a fresh (empty) table so re-apply is a no-op.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM serving.downtime_events_resolved LIMIT 1) THEN
        PERFORM serving.refresh_downtime_events_resolved(now()-interval '150 days', now());
        UPDATE serving.downtime_events_resolved_meta SET coverage_from = now()-interval '150 days' WHERE id=1;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_name='job_refresh_downtime_events_resolved') THEN
        PERFORM add_job('serving.job_refresh_downtime_events_resolved', schedule_interval => interval '2 minutes');
    END IF;
END $$;
