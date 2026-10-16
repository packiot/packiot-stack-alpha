-- rollback for t-prodt170-operator-events-windows: restores the fixed windows (pending 4 days; history started in
-- 7 days and ended in the last day) — the definitions live on staging before this migration (t-operator-events-dedupe
-- + t-no-data-status' status NOT IN (6, 20)) — and drops the window functions and the four enterprise columns.
-- ORDER: roll edge-api back FIRST (from PRODT-170 on it selects/edits these columns), then this; read-api's
-- /v2/events-window then answers 500 and the operator just hides its window label.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
SET search_path = serving, silver, core, public;
CREATE OR REPLACE FUNCTION serving.pending_downtime(in_packml_topic character varying[])
 RETURNS SETOF pending_downtime_row
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
  -- Same plan-time pruning as events_timeline (literal bound instead of now()).
  RETURN QUERY EXECUTE format($q$
	SELECT id_equipment_event, ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic
    FROM equipment_events ee
    JOIN equipments e ON ee.id_equipment = e.id_equipment
    JOIN LATERAL (
        -- ONE topic per equipment: a machine has its base topic + counter leaf topics
        -- (…/Admin/Prod*Count/…); joining them all returned each event once PER TOPIC
        -- (L5: 279 rows for 72 events). Pick the shortest requested = the base topic.
        SELECT pr.packml_topic FROM packml_register pr
         WHERE pr.id_equipment = e.id_equipment AND pr.packml_topic = ANY ($1)
         ORDER BY length(pr.packml_topic), pr.packml_topic LIMIT 1) p ON true
    WHERE TRUE
        AND ee.ts_event >= %1$L::timestamptz
        AND ee.status NOT IN (6, 20)
        AND (ee.duration >= COALESCE(e.stop_threshold_time, 0) or ee.duration is null)
        and ee.cd_category is null
        -- Line-lead mirror dedupe (same rule as #1442 v_events_2): a MACHINE stop whose
        -- top-parent line carries the exact mirror (same ts_event + status) is shown once,
        -- as the line's copy — regardless of the mirror's classification, so justifying
        -- the line copy never resurfaces the machine copy as pending.
        AND NOT (e.tp_equipment = 1 AND EXISTS (
              SELECT 1 FROM equipments pe
                LEFT JOIN equipments ppe ON ppe.id_equipment = pe.id_parentequipment
                JOIN equipment_events le ON le.id_equipment = COALESCE(ppe.id_equipment, pe.id_equipment)
               WHERE pe.id_equipment = e.id_parentequipment
                 AND le.ts_event = ee.ts_event AND le.status = ee.status))
    ORDER BY ts_event DESC
  $q$, now() - interval '4 days') USING in_packml_topic;
END
$function$

;
CREATE OR REPLACE FUNCTION serving.events_timeline(in_packml_topic character varying[])
 RETURNS SETOF events_timeline_row
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
  -- PLAN-TIME chunk pruning: the time bounds are spliced in as LITERALS (format %L), so
  -- TimescaleDB excludes old chunks while PLANNING. As an inlined SQL function with
  -- now() the planner built paths for EVERY chunk of silver.equipment_events (1,599
  -- after the T1 backfill): planning 22.8 s vs execution 96 ms → read-api 15 s 500s.
  RETURN QUERY EXECUTE format($q$

select
	id_equipment_event,
  ts_event,
  ee.ts_end,
  duration,
  e.id_equipment,
  e.id_enterprise,
  txt_downtime_notes,
  cd_machine,
  cd_category,
  cd_subcategory,
  change_over,
  desc_category,
  desc_subcategory,
  p.packml_topic,
  'downtime' :: text as event_type,
  po.id_order_text,
  po.id_production_order,
  po.production_programmed,
  po.custom_field
FROM
  equipment_events ee
  JOIN equipments e ON ee.id_equipment = e.id_equipment
  JOIN LATERAL (
        -- ONE topic per equipment: a machine has its base topic + counter leaf topics
        -- (…/Admin/Prod*Count/…); joining them all returned each event once PER TOPIC
        -- (L5: 279 rows for 72 events). Pick the shortest requested = the base topic.
        SELECT pr.packml_topic FROM packml_register pr
         WHERE pr.id_equipment = e.id_equipment AND pr.packml_topic = ANY ($1)
         ORDER BY length(pr.packml_topic), pr.packml_topic LIMIT 1) p ON true
  left join production_orders_runtime por on (ee.id_equipment = por.id_equipment  and ee.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
where
  TRUE
  -- Partition-column bound (t-events-timeline-bound, 2026-09-24): WITHOUT a ts_event
  -- predicate TimescaleDB cannot exclude chunks, so every call scanned + decompressed the
  -- WHOLE silver.equipment_events history (5 y after the T1 backfill) → >15 s → read-api
  -- 500 → operator HISTORIC list empty for every tenant. 7 days covers any event that
  -- ended within the last day unless it lasted >6 days; also drops never-closed junk.
  AND ee.ts_event >= %1$L::timestamptz
  AND (ee.ts_end >= %2$L::timestamptz OR ee.ts_end IS NULL)
  AND ((ee.duration >= COALESCE(e.stop_threshold_time, 0)) or (ee.ts_end is null or ee.cd_category is not null))
  AND ee.status NOT IN (6, 20)
  and ee.cd_category is not null
  -- Line-lead mirror dedupe (same rule as #1442 v_events_2): a MACHINE stop whose
  -- top-parent line carries the exact mirror (same ts_event + status) is shown once,
  -- as the line's copy — regardless of the mirror's classification, so justifying
  -- the line copy never resurfaces the machine copy as pending.
  AND NOT (e.tp_equipment = 1 AND EXISTS (
              SELECT 1 FROM equipments pe
                LEFT JOIN equipments ppe ON ppe.id_equipment = pe.id_parentequipment
                JOIN equipment_events le ON le.id_equipment = COALESCE(ppe.id_equipment, pe.id_equipment)
               WHERE pe.id_equipment = e.id_parentequipment
           AND le.ts_event = ee.ts_event AND le.status = ee.status))
union
select
	eels.id_equipment_event  as id_equipment_event,
	eels.ts_event as ts_event,
	eels.ts_end as ts_end,
	eels.duration,
	e.id_equipment,
	e.id_enterprise,
	eels.txt_downtime_notes,
	eels.cd_machine,
	eels.cd_category,
	eels.desc_category,
	eels.change_over,
	eels.desc_subcategory,
	eels.cd_subcategory,
	p.packml_topic,
	'low_speed' :: text as event_type,
	po.id_order_text,
	po.id_production_order,
	po.production_programmed,
	po.custom_field
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN LATERAL (
        -- ONE topic per equipment: a machine has its base topic + counter leaf topics
        -- (…/Admin/Prod*Count/…); joining them all returned each event once PER TOPIC
        -- (L5: 279 rows for 72 events). Pick the shortest requested = the base topic.
        SELECT pr.packml_topic FROM packml_register pr
         WHERE pr.id_equipment = e.id_equipment AND pr.packml_topic = ANY ($1)
         ORDER BY length(pr.packml_topic), pr.packml_topic LIMIT 1) p ON true
	left join production_orders_runtime por on (eels.id_equipment = por.id_equipment  and eels.ts_event <@ por.runtime_timerange)
	left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
	TRUE
	AND eels.ts_event >= %2$L::timestamptz
	AND (eels.status = 1 OR eels.status = 2)  -- was unparenthesized: status=2 rows bypassed the topic + time filters	
UNION
select
	eem.id_equipment_event as id_equipment_event,
  eem.ts_event as ts_event,
  eem.ts_end as ts_end,
  extract(
    epoch
    from
      (eem.ts_end - eem.ts_event)
  ) :: integer as duration,
  e.id_equipment,
  e.id_enterprise,
  eem.txt_downtime_notes,
  eem.cd_machine,
  eem.cd_category,
  eem.cd_subcategory,
  eem.change_over,
  eem.desc_category,
  eem.desc_subcategory,
  p.packml_topic,
  'manual' :: text as event_type,
  po.id_order_text,
  po.id_production_order,
  po.production_programmed,
  po.custom_field
FROM
  equipment_events_man eem
  JOIN equipments e ON eem.id_equipment = e.id_equipment
  JOIN LATERAL (
        -- ONE topic per equipment: a machine has its base topic + counter leaf topics
        -- (…/Admin/Prod*Count/…); joining them all returned each event once PER TOPIC
        -- (L5: 279 rows for 72 events). Pick the shortest requested = the base topic.
        SELECT pr.packml_topic FROM packml_register pr
         WHERE pr.id_equipment = e.id_equipment AND pr.packml_topic = ANY ($1)
         ORDER BY length(pr.packml_topic), pr.packml_topic LIMIT 1) p ON true
  left join production_orders_runtime por on (eem.id_equipment = por.id_equipment  and eem.ts_event <@ por.runtime_timerange)
  left join production_orders po on (por.id_production_order = po.id_production_order)
WHERE
  TRUE
  AND eem.ts_event >= %2$L::timestamptz
   -- AND eem.status NOT IN (6, 20) -- Não tem status nessa table
  -- AND ee.cd_category is null -- nem cd_category
ORDER BY
  ts_event DESC
  $q$, now() - interval '7 days', now() - interval '1 days') USING in_packml_topic;
END
$function$

;
COMMENT ON FUNCTION serving.pending_downtime(character varying[]) IS 'serving: pending (unjustified) downtime for a set of packml topics. read-api /v1/pending-downtime with outer WHERE id_enterprise=$1 (operator).';
COMMENT ON FUNCTION serving.events_timeline(character varying[]) IS 'serving: event timeline for a set of packml topics. read-api /v1/events-timeline with outer WHERE id_enterprise=$1 (operator, byte-stable shape).';
DROP FUNCTION IF EXISTS serving.operator_events_window_by_equipment(integer[]);
DROP FUNCTION IF EXISTS serving.operator_events_window_at(integer[], timestamptz);
DROP FUNCTION IF EXISTS serving.operator_window_start(integer, text, integer, timestamptz);
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_operator_pending_window_check,
  DROP CONSTRAINT IF EXISTS enterprises_operator_history_window_check,
  DROP CONSTRAINT IF EXISTS enterprises_operator_pending_hours_check,
  DROP CONSTRAINT IF EXISTS enterprises_operator_history_hours_check;
ALTER TABLE core.enterprises DROP COLUMN IF EXISTS operator_pending_window, DROP COLUMN IF EXISTS operator_pending_hours,
  DROP COLUMN IF EXISTS operator_history_window, DROP COLUMN IF EXISTS operator_history_hours;
COMMIT;
