-- t-prodt170-operator-events-windows — PRODT-170 (RN-17, RN-18, AC-20, AC-21): each enterprise sets the time
-- window of the operator's PENDING list and HISTORY list (Events tab) in CS Admin.
--
-- BEFORE: fixed literals in serving.pending_downtime (stops that STARTED in the last 4 days) and
-- serving.events_timeline (started in the last 7 days AND ended in the last day; low-speed/manual: started in the
-- last day). Not configurable, and the history rule was on the END time.
--
-- NOW, per enterprise (core.enterprises.operator_{pending,history}_{window,hours}):
--   window = 'shift'           the stops that STARTED in the CURRENT SHIFT of the stop's equipment
--                              (piot_get_shift_hour_begin_by_equipment: equipment > area > site > enterprise calendar;
--                              between two shifts, when no shift is running, it falls back to the production day)
--   window = 'production_day'  the stops that STARTED in the current PRODUCTION DAY (piot_get_day_begin_by_equipment:
--                              area day_begin, else site day_begin, in the site's timezone). NOT the UTC date: a site
--                              whose day starts at 23:10 local (day_begin -3000, Sao Paulo) starts it at 02:10 UTC.
--   window = 'hours'           the stops that STARTED in the last N hours (1..168)
--   The start is clamped to at most 7 days back (RN-18), whatever the calendar says.
--   ONGOING stops (ts_end IS NULL) are ALWAYS pending, even when they started before the window (AC-20) — up to the
--   same 7-day literal bound every events query keeps (NFR-01: the planner prunes old partitions only on a literal).
-- Defaults (product owner, 2026-10-16): pending = current production day, history = last 24 hours.
--
-- SHAPE: the v1 functions keep their signatures and row types (read-api /v1 and the /v2 by-equipment wrappers call
-- them, so both pick up the windows with no read-api change), and the badge stays the length of the pending list
-- (operator), i.e. the same window by construction. One NEW read: serving.operator_events_window_by_equipment —
-- read-api GET /v2/events-window — so the operator can say which window it shows.
--
-- Bodies = the LIVE definitions (t-operator-events-dedupe + t-no-data-status' `status NOT IN (6, 20)`), with only the
-- time predicates changed, plus one fix in events_timeline's low-speed branch: its category columns were listed in a
-- different order than the other two UNION branches, so desc_category arrived as cd_subcategory, etc.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';
SET search_path = serving, silver, core, public;

-- ── the setting: four columns on the enterprise (constant defaults → no table rewrite) ──────────────────────────
ALTER TABLE core.enterprises
  ADD COLUMN IF NOT EXISTS operator_pending_window text    NOT NULL DEFAULT 'production_day',
  ADD COLUMN IF NOT EXISTS operator_pending_hours  integer NOT NULL DEFAULT 24,
  ADD COLUMN IF NOT EXISTS operator_history_window text    NOT NULL DEFAULT 'hours',
  ADD COLUMN IF NOT EXISTS operator_history_hours  integer NOT NULL DEFAULT 24;

ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_operator_pending_window_check;
ALTER TABLE core.enterprises ADD CONSTRAINT enterprises_operator_pending_window_check
  CHECK (operator_pending_window IN ('shift', 'production_day', 'hours'));
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_operator_history_window_check;
ALTER TABLE core.enterprises ADD CONSTRAINT enterprises_operator_history_window_check
  CHECK (operator_history_window IN ('shift', 'production_day', 'hours'));
-- 168 h = 7 days, the RN-18 ceiling
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_operator_pending_hours_check;
ALTER TABLE core.enterprises ADD CONSTRAINT enterprises_operator_pending_hours_check
  CHECK (operator_pending_hours BETWEEN 1 AND 168);
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_operator_history_hours_check;
ALTER TABLE core.enterprises ADD CONSTRAINT enterprises_operator_history_hours_check
  CHECK (operator_history_hours BETWEEN 1 AND 168);

COMMENT ON COLUMN core.enterprises.operator_pending_window IS
  'PRODT-170 RN-18: operator Events tab PENDING list window — shift | production_day | hours (applies to a stop''s START; ongoing stops always shown; max 7 days). Edited in CS Admin.';
COMMENT ON COLUMN core.enterprises.operator_pending_hours IS
  'PRODT-170: N of the pending window when operator_pending_window = ''hours'' (1..168).';
COMMENT ON COLUMN core.enterprises.operator_history_window IS
  'PRODT-170 RN-18: operator Events tab HISTORY list window — shift | production_day | hours (applies to a stop''s START; max 7 days). Edited in CS Admin.';
COMMENT ON COLUMN core.enterprises.operator_history_hours IS
  'PRODT-170: N of the history window when operator_history_window = ''hours'' (1..168).';

-- The staging mirror's reflector updates core.enterprises with a COLUMN-LEVEL grant (t-prod-reflector-roles lists
-- the columns that existed then): extend it, or reflecting production's values would fail once production has them.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prod_reflector') THEN
    GRANT UPDATE (operator_pending_window, operator_pending_hours, operator_history_window, operator_history_hours)
      ON core.enterprises TO prod_reflector;
  END IF;
END $$;

-- ── window start: one place computes it, for the lists AND for the label the operator shows ─────────────────────
CREATE OR REPLACE FUNCTION serving.operator_window_start(p_id_equipment integer, p_window text, p_hours integer,
                                                         p_now timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  v timestamptz;
BEGIN
  IF p_window = 'shift' THEN
    SELECT s.ts_begin INTO v FROM public.piot_get_shift_hour_begin_by_equipment(p_id_equipment, p_now) s LIMIT 1;
  END IF;
  -- production day; also the fallback of 'shift' when no shift is running now (gap between shifts, no calendar)
  IF p_window = 'production_day' OR (p_window = 'shift' AND v IS NULL) THEN
    SELECT d.ts_value INTO v FROM public.piot_get_day_begin_by_equipment(p_id_equipment, p_now) d LIMIT 1;
  END IF;
  IF v IS NULL THEN   -- 'hours', or a calendar that cannot be resolved (no site timezone): last N / 24 hours
    v := p_now - make_interval(hours => CASE WHEN p_window = 'hours' THEN least(greatest(coalesce(p_hours, 24), 1), 168)
                                             ELSE 24 END);
  END IF;
  -- never in the future, never more than 7 days back (RN-18)
  RETURN greatest(least(v, p_now), p_now - interval '7 days');
END
$fn$;
COMMENT ON FUNCTION serving.operator_window_start(integer, text, integer, timestamptz) IS
  'PRODT-170: start of an operator Events window for one equipment at p_now — shift (current shift, else production day), production_day (piot_get_day_begin_by_equipment, NOT the UTC date) or the last N hours; clamped to [p_now - 7 days, p_now].';

CREATE OR REPLACE FUNCTION serving.operator_events_window_at(in_id_equipment integer[], p_now timestamptz)
RETURNS TABLE (id_equipment integer, id_enterprise integer,
               pending_window text, pending_hours integer, pending_start timestamptz,
               history_window text, history_hours integer, history_start timestamptz)
LANGUAGE sql STABLE
AS $fn$
  SELECT e.id_equipment, e.id_enterprise,
         en.operator_pending_window, en.operator_pending_hours,
         serving.operator_window_start(e.id_equipment, en.operator_pending_window, en.operator_pending_hours, p_now),
         en.operator_history_window, en.operator_history_hours,
         serving.operator_window_start(e.id_equipment, en.operator_history_window, en.operator_history_hours, p_now)
    FROM core.equipments e
    JOIN core.enterprises en ON en.id_enterprise = e.id_enterprise
   WHERE e.id_equipment = ANY (in_id_equipment)
$fn$;
COMMENT ON FUNCTION serving.operator_events_window_at(integer[], timestamptz) IS
  'PRODT-170: the enterprise''s pending/history window of each equipment, with their starts at p_now. The pending and history lists filter with exactly these starts.';

-- read-api GET /v2/events-window (the operator's "showing stops since …" label)
CREATE OR REPLACE FUNCTION serving.operator_events_window_by_equipment(in_id_equipment integer[])
RETURNS TABLE (id_equipment integer, id_enterprise integer,
               pending_window text, pending_hours integer, pending_start timestamptz,
               history_window text, history_hours integer, history_start timestamptz)
LANGUAGE sql STABLE
AS $fn$
  SELECT * FROM serving.operator_events_window_at(in_id_equipment, now())
$fn$;
COMMENT ON FUNCTION serving.operator_events_window_by_equipment(integer[]) IS
  'PRODT-170: read-api /v2/events-window — the pending/history windows (kind, hours, start) the Events lists use now.';

-- ── pending: no reason, at least the minimum stop time OR ongoing; started in the window OR ongoing ─────────────
CREATE OR REPLACE FUNCTION serving.pending_downtime(in_packml_topic character varying[])
 RETURNS SETOF pending_downtime_row
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_now    timestamptz := now();
  v_ids    integer[];
  v_starts timestamptz[];
BEGIN
  -- PRODT-170: the enterprise's pending window, per requested equipment (few rows: one line + its members).
  SELECT array_agg(w.id_equipment), array_agg(w.pending_start) INTO v_ids, v_starts
    FROM serving.operator_events_window_at(
           ARRAY(SELECT DISTINCT pr.id_equipment FROM packml_register pr
                  WHERE pr.packml_topic = ANY (in_packml_topic) AND pr.id_equipment IS NOT NULL), v_now) w;
  IF v_ids IS NULL THEN
    RETURN;
  END IF;
  -- Plan-time pruning: %1$L is a LITERAL (7 days = the RN-18 ceiling and the bound of an ongoing stop); the
  -- per-equipment window start ($3) narrows it at run time.
  RETURN QUERY EXECUTE format($q$
	SELECT id_equipment_event, ts_event, ts_end, duration, e.id_equipment, e.id_enterprise, p.packml_topic
    FROM equipment_events ee
    JOIN equipments e ON ee.id_equipment = e.id_equipment
    JOIN unnest($2::integer[], $3::timestamptz[]) AS w(id_equipment, win_start) ON w.id_equipment = e.id_equipment
    JOIN LATERAL (
        -- ONE topic per equipment: a machine has its base topic + counter leaf topics
        -- (…/Admin/Prod*Count/…); joining them all returned each event once PER TOPIC
        -- (L5: 279 rows for 72 events). Pick the shortest requested = the base topic.
        SELECT pr.packml_topic FROM packml_register pr
         WHERE pr.id_equipment = e.id_equipment AND pr.packml_topic = ANY ($1)
         ORDER BY length(pr.packml_topic), pr.packml_topic LIMIT 1) p ON true
    WHERE TRUE
        AND ee.ts_event >= %1$L::timestamptz
        -- RN-18: the window applies to the START; an ongoing stop is always pending (AC-20)
        AND (ee.ts_event >= w.win_start OR ee.ts_end IS NULL)
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
  $q$, v_now - interval '7 days') USING in_packml_topic, v_ids, v_starts;
END
$function$;

-- ── history: stops with a reason (+ low-speed and manual events) that started in the window ─────────────────────
CREATE OR REPLACE FUNCTION serving.events_timeline(in_packml_topic character varying[])
 RETURNS SETOF events_timeline_row
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_now    timestamptz := now();
  v_ids    integer[];
  v_starts timestamptz[];
BEGIN
  -- PRODT-170: the enterprise's history window, per requested equipment.
  SELECT array_agg(w.id_equipment), array_agg(w.history_start) INTO v_ids, v_starts
    FROM serving.operator_events_window_at(
           ARRAY(SELECT DISTINCT pr.id_equipment FROM packml_register pr
                  WHERE pr.packml_topic = ANY (in_packml_topic) AND pr.id_equipment IS NOT NULL), v_now) w;
  IF v_ids IS NULL THEN
    RETURN;
  END IF;
  -- PLAN-TIME chunk pruning: the time bound is spliced in as a LITERAL (format %L), so the planner excludes old
  -- partitions while PLANNING (with now() it built paths for every chunk: planning 22.8 s → read-api 15 s 500s,
  -- t-events-timeline-bound). %1$L = 7 days (the RN-18 ceiling); $3 = the per-equipment window start.
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
  JOIN unnest($2::integer[], $3::timestamptz[]) AS w(id_equipment, win_start) ON w.id_equipment = e.id_equipment
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
  AND ee.ts_event >= %1$L::timestamptz
  AND ee.ts_event >= w.win_start          -- RN-18: the window applies to the START
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
	-- same column order as the other branches (was cd_category, desc_category, change_over, desc_subcategory,
	-- cd_subcategory: low-speed rows carried desc_category in cd_subcategory, and so on)
	eels.cd_category,
	eels.cd_subcategory,
	eels.change_over,
	eels.desc_category,
	eels.desc_subcategory,
	p.packml_topic,
	'low_speed' :: text as event_type,
	po.id_order_text,
	po.id_production_order,
	po.production_programmed,
	po.custom_field
FROM
	equipment_events_low_speed eels
	JOIN equipments e ON eels.id_equipment = e.id_equipment
	JOIN unnest($2::integer[], $3::timestamptz[]) AS w(id_equipment, win_start) ON w.id_equipment = e.id_equipment
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
	AND eels.ts_event >= %1$L::timestamptz
	AND eels.ts_event >= w.win_start
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
  JOIN unnest($2::integer[], $3::timestamptz[]) AS w(id_equipment, win_start) ON w.id_equipment = e.id_equipment
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
  AND eem.ts_event >= %1$L::timestamptz
  AND eem.ts_event >= w.win_start
ORDER BY
  ts_event DESC
  $q$, v_now - interval '7 days') USING in_packml_topic, v_ids, v_starts;
END
$function$;

COMMENT ON FUNCTION serving.pending_downtime(character varying[]) IS
  'serving: pending (unjustified) downtime for a set of packml topics — no reason, at least stop_threshold_time or ongoing; started in the enterprise''s pending window (PRODT-170) or ongoing. read-api /v1/pending-downtime with outer WHERE id_enterprise=$1 (operator).';
COMMENT ON FUNCTION serving.events_timeline(character varying[]) IS
  'serving: event timeline (justified stops, low-speed, manual) for a set of packml topics that started in the enterprise''s history window (PRODT-170). read-api /v1/events-timeline with outer WHERE id_enterprise=$1 (operator, byte-stable shape).';

GRANT EXECUTE ON FUNCTION serving.operator_window_start(integer, text, integer, timestamptz),
  serving.operator_events_window_at(integer[], timestamptz),
  serving.operator_events_window_by_equipment(integer[])
  TO readapi_ro, superset_ro, bi_owner;

COMMIT;
