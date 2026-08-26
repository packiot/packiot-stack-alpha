-- ============================================================================
-- f3-phasec-history-backfill.sql
-- Phase-C deep-history backfill for the CPACK twin on the STAGING stack.
--   Source : packiot            (F1, pre-cutover)   ent-3  CPACK-Staging
--   Target : packiot_analytics  (F3, live twin)     ent-3  CPACK-Staging
--   Both DBs live on the same host -> copy over dblink in ONE transaction.
--
-- WHY this is not a plain copy: F1 and F3 hold the same production_orders under
-- DIVERGENT surrogate PKs (id_production_order) but a STABLE business key
-- (id_enterprise, id_order). A naive PK copy would collide with / corrupt live
-- F3 rows. So POs are matched/deduped by the business key and re-minted with a
-- FRESH F3 identity PK; production_orders_runtime.id_production_order is remapped
-- to that fresh PK via id_order. equipment_events key on the NATURAL composite
-- (id_equipment, ts_event) -> pure ON CONFLICT DO NOTHING, no remap.
--
-- Idempotent (re-runnable), business-key-aware, reversible (see companion
-- f3-phasec-history-backfill.reverse.sql). History is loaded recalc_needed=false
-- so the live oeecloud-worker recompute loop is never triggered on rows whose
-- raw counters are not present in F3.
--
-- Run DRY (BEGIN..ROLLBACK, prints before/after + collision checks):
--   psql -v dryrun=true  -f f3-phasec-history-backfill.sql
-- Run LIVE (COMMIT):
--   psql -v dryrun=false -f f3-phasec-history-backfill.sql
-- ============================================================================

\set ON_ERROR_STOP on
\timing on

BEGIN;

CREATE EXTENSION IF NOT EXISTS dblink;
-- F1 source connection. Pass the secret at run time, never commit it:
--   psql -v f1conn="host=127.0.0.1 dbname=packiot user=postgres password=***" ...
-- Default omits the password (works when local pg_hba grants trust/peer).
\if :{?f1conn}
\else
  \set f1conn 'host=127.0.0.1 dbname=packiot user=postgres'
\endif
SELECT dblink_connect('f1src', :'f1conn');

-- Snapshot the F3 CPACK id_order set that exists BEFORE the backfill.
-- Everything we mint is, by definition, an id_order not in this set. This is the
-- isolation boundary for the runtime remap AND the reversal script.
CREATE TEMP TABLE _pre_po ON COMMIT DROP AS
  SELECT id_order FROM production_orders WHERE id_enterprise = 3;

-- Cutover instant: F3's earliest existing ent-3 event. The deep-history event
-- backfill is fenced STRICTLY BEFORE this. F1 events at/after it belong to the
-- pre-cutover parallel stream and overlap F3's live reality (ambiguous:
-- dropped-vs-phantom) -> deliberately NOT copied. Captured before any insert.
CREATE TEMP TABLE _evt_fence ON COMMIT DROP AS
  SELECT COALESCE(min(ts_event), 'infinity'::timestamptz) AS boundary
  FROM equipment_events WHERE id_enterprise = 3;

-- Shift-grain fence: F3's earliest ent-3 equipment_runtime_shift.ts_value. This
-- grain GATES v_report_downtimes (the view inner-joins it), so deep-history
-- events cannot surface until the pre-cutover shift rows are present. Backfill
-- strictly before this instant; F3 already owns the live rows at/after it.
CREATE TEMP TABLE _shift_fence ON COMMIT DROP AS
  SELECT COALESCE(min(s.ts_value), 'infinity'::timestamptz) AS boundary
  FROM equipment_runtime_shift s
  JOIN equipments e ON e.id_equipment = s.id_equipment AND e.id_enterprise = 3;

-- BEFORE counts (kept across the txn for the final report).
CREATE TEMP TABLE _before ON COMMIT DROP AS
SELECT
  (SELECT count(*) FROM production_orders WHERE id_enterprise=3)                         AS po,
  (SELECT count(*) FROM production_orders_runtime por
       JOIN production_orders po ON po.id_production_order=por.id_production_order
     WHERE po.id_enterprise=3)                                                           AS runtime,
  (SELECT count(*) FROM equipment_events WHERE id_enterprise=3)                          AS events,
  (SELECT count(*) FROM equipment_events_man WHERE id_enterprise=3)                      AS events_man,
  (SELECT count(*) FROM user_logs WHERE id_enterprise=3)                                 AS user_logs,
  (SELECT count(*) FROM equipment_runtime_shift s
       JOIN equipments e ON e.id_equipment=s.id_equipment AND e.id_enterprise=3)          AS runtime_shift,
  (SELECT count(*) FROM v_report_downtimes WHERE id_enterprise=3 AND op IS NOT NULL)     AS vdt_op_notnull,
  (SELECT count(*) FROM v_report_downtimes WHERE id_enterprise=3 AND op IS NULL)         AS vdt_op_null,
  (SELECT count(*) FROM v_report_downtimes WHERE id_enterprise=3)                        AS vdt_total;

-- ---------------------------------------------------------------------------
-- A. production_orders  (business-key insert, fresh F3 PK)
--    Pull ALL F1 ent-3 POs; the 11 that already exist collide on the
--    (id_enterprise, id_order) UNIQUE and are skipped. recalc_needed forced
--    false. id_production_order is NOT copied -> F3 identity mints a fresh PK.
-- ---------------------------------------------------------------------------
INSERT INTO production_orders (
  id_enterprise,id_site,id_area,id_equipment,id_product,id_client,status,
  production_programmed,production_ordered,id_order,id_user_operator,id_equipment_executed,
  production_real,production_final,ts_start,ts_end,equipment_setup,oee_processed,
  oee_quality,oee_performance,oee_availability,oee,available_time,running_time,stopped_time,
  planned_downtime,ideal_production,qt_stops,erp_processed,gross_production,ts_creation,
  ts_start_tz,ts_end_tz,txt_production_order_notes,txt_production_order_description,
  conversion_factor,net_production,speed,ideal_production_speed,id_order_text,custom_field,
  recalc_needed,last_update,nm_production_order,multiplier,id_label)
SELECT
  f1.id_enterprise,f1.id_site,f1.id_area,f1.id_equipment,f1.id_product,f1.id_client,f1.status,
  f1.production_programmed,f1.production_ordered,f1.id_order,f1.id_user_operator,f1.id_equipment_executed,
  f1.production_real,f1.production_final,f1.ts_start,f1.ts_end,f1.equipment_setup,f1.oee_processed,
  -- OEE ratio cols: F1 stores measurement artifacts >1 (e.g. quality 1.12) that
  -- violate F3's [0,1] CHECK. NULL-preserving clamp to the domain boundary.
  CASE WHEN f1.oee_quality      IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee_quality))      END,
  CASE WHEN f1.oee_performance  IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee_performance))  END,
  CASE WHEN f1.oee_availability IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee_availability)) END,
  CASE WHEN f1.oee             IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee))              END,
  f1.available_time,f1.running_time,f1.stopped_time,
  f1.planned_downtime,f1.ideal_production,f1.qt_stops,f1.erp_processed,f1.gross_production,f1.ts_creation,
  f1.ts_start_tz,f1.ts_end_tz,f1.txt_production_order_notes,f1.txt_production_order_description,
  f1.conversion_factor,f1.net_production,f1.speed,f1.ideal_production_speed,f1.id_order_text,f1.custom_field,
  false AS recalc_needed,f1.last_update,f1.nm_production_order,f1.multiplier,f1.id_label
FROM dblink('f1src', $q$
  SELECT id_production_order, id_enterprise, id_site, id_area, id_equipment, id_product,
         id_client, status, production_programmed, production_ordered, id_order, id_user_operator,
         id_equipment_executed, production_real, production_final, ts_start, ts_end, equipment_setup,
         oee_processed, oee_quality, oee_performance, oee_availability, oee, available_time, running_time,
         stopped_time, planned_downtime, ideal_production, qt_stops, erp_processed, gross_production,
         ts_creation, ts_start_tz, ts_end_tz, txt_production_order_notes, txt_production_order_description,
         conversion_factor, net_production, speed, ideal_production_speed, id_order_text, custom_field,
         recalc_needed, last_update, nm_production_order, multiplier, id_label
  FROM production_orders WHERE id_enterprise = 3
$q$) AS f1(
  id_production_order int8, id_enterprise int4, id_site int4, id_area int4, id_equipment int4,
  id_product int4, id_client int4, status int4, production_programmed int8, production_ordered int8,
  id_order int4, id_user_operator int4, id_equipment_executed int4, production_real int8, production_final int8,
  ts_start timestamptz, ts_end timestamptz, equipment_setup jsonb, oee_processed bool, oee_quality float4,
  oee_performance float4, oee_availability float4, oee float4, available_time int4, running_time int4,
  stopped_time int4, planned_downtime int4, ideal_production int4, qt_stops int4, erp_processed bool,
  gross_production float8, ts_creation timestamptz, ts_start_tz timestamptz, ts_end_tz timestamptz,
  txt_production_order_notes varchar, txt_production_order_description varchar, conversion_factor float4,
  net_production float8, speed float4, ideal_production_speed int4, id_order_text varchar, custom_field jsonb,
  recalc_needed bool, last_update timestamptz, nm_production_order varchar, multiplier float8, id_label int8)
ON CONFLICT (id_enterprise, id_order) DO NOTHING;

-- Newly-minted PO set (the id_orders that were absent before this run).
CREATE TEMP TABLE _new_po ON COMMIT DROP AS
SELECT po.id_production_order, po.id_order, po.id_equipment
FROM production_orders po
WHERE po.id_enterprise = 3
  AND po.id_order NOT IN (SELECT id_order FROM _pre_po);

-- ---------------------------------------------------------------------------
-- B. production_orders_runtime  (remap id_production_order F1 PK -> F3 PK by
--    id_order; only for the newly-minted POs; skip if a runtime row already
--    exists for that PO or would violate the (id_equipment, timerange) EXCLUDE).
-- ---------------------------------------------------------------------------
INSERT INTO production_orders_runtime (
  id_production_order, runtime_timerange, oee, recalc_needed, oee_p, oee_a, oee_q,
  available_time, running_time, stopped_time, planned_downtime, ideal_production,
  idle_time, idle_starved, idle_blocked, id_equipment, net_production, gross_production,
  downtime, changeover_time, speed, last_update, multiplier)
SELECT
  np.id_production_order,            -- FRESH F3 PK
  f1r.runtime_timerange,
  CASE WHEN f1r.oee   IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1r.oee))   END,
  false AS recalc_needed,
  CASE WHEN f1r.oee_p IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1r.oee_p)) END,
  CASE WHEN f1r.oee_a IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1r.oee_a)) END,
  CASE WHEN f1r.oee_q IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1r.oee_q)) END,
  f1r.available_time, f1r.running_time, f1r.stopped_time, f1r.planned_downtime, f1r.ideal_production,
  f1r.idle_time, f1r.idle_starved, f1r.idle_blocked, f1r.id_equipment, f1r.net_production, f1r.gross_production,
  f1r.downtime, f1r.changeover_time, f1r.speed, f1r.last_update, f1r.multiplier
FROM dblink('f1src', $q$
  SELECT po.id_order AS src_id_order, r.runtime_timerange, r.oee, r.oee_p, r.oee_a, r.oee_q,
         r.available_time, r.running_time, r.stopped_time, r.planned_downtime, r.ideal_production,
         r.idle_time, r.idle_starved, r.idle_blocked, r.id_equipment, r.net_production, r.gross_production,
         r.downtime, r.changeover_time, r.speed, r.last_update, r.multiplier
  FROM production_orders_runtime r
  JOIN production_orders po ON po.id_production_order = r.id_production_order
  WHERE po.id_enterprise = 3
$q$) AS f1r(
  src_id_order int4, runtime_timerange tstzrange, oee float4, oee_p float4, oee_a float4, oee_q float4,
  available_time int4, running_time int4, stopped_time int4, planned_downtime int4, ideal_production float8,
  idle_time int4, idle_starved int4, idle_blocked int4, id_equipment int4, net_production float8,
  gross_production float8, downtime int4, changeover_time int4, speed float4, last_update timestamptz,
  multiplier float8)
JOIN _new_po np ON np.id_order = f1r.src_id_order
WHERE f1r.runtime_timerange IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM production_orders_runtime x
                    WHERE x.id_production_order = np.id_production_order)
  AND NOT EXISTS (SELECT 1 FROM production_orders_runtime y
                    WHERE y.id_equipment = f1r.id_equipment
                      AND y.runtime_timerange && f1r.runtime_timerange);

-- ---------------------------------------------------------------------------
-- C. equipment_events  (deep-history downtimes/events, verbatim). NATURAL PK
--    (id_equipment, ts_event) -> ON CONFLICT DO NOTHING. Copies ALL F1 ent-3
--    events; those already present (post-cutover overlap window) are skipped,
--    live F3 rows are never overwritten. source_seq keeps legacy provenance.
-- ---------------------------------------------------------------------------
INSERT INTO equipment_events (
  id_equipment, ts_event, status, id_equipment_event, txt_downtime_notes, idle, idle_processed,
  forced_creation_system, fault, fault_processed, cd_machine, cd_category, cd_subcategory, change_over,
  planned_downtime, ts_end, duration, id_enterprise, desc_category, desc_subcategory, cd_category_client,
  cd_subcategory_client, last_update, ignore_cost, source_seq)
SELECT
  f1.id_equipment, f1.ts_event, f1.status, f1.id_equipment_event, f1.txt_downtime_notes, f1.idle,
  f1.idle_processed, f1.forced_creation_system, f1.fault, f1.fault_processed, f1.cd_machine, f1.cd_category,
  f1.cd_subcategory, f1.change_over, f1.planned_downtime, f1.ts_end, f1.duration, f1.id_enterprise,
  f1.desc_category, f1.desc_subcategory, f1.cd_category_client, f1.cd_subcategory_client, f1.last_update,
  f1.ignore_cost, f1.id_equipment_event AS source_seq
FROM dblink('f1src', $q$
  SELECT id_equipment, ts_event, status, id_equipment_event, txt_downtime_notes, idle, idle_processed,
         forced_creation_system, fault, fault_processed, cd_machine, cd_category, cd_subcategory, change_over,
         planned_downtime, ts_end, duration, id_enterprise, desc_category, desc_subcategory, cd_category_client,
         cd_subcategory_client, last_update, ignore_cost
  FROM equipment_events WHERE id_enterprise = 3
$q$) AS f1(
  id_equipment int4, ts_event timestamptz, status int4, id_equipment_event int8, txt_downtime_notes varchar,
  idle varchar, idle_processed bool, forced_creation_system bool, fault int4, fault_processed bool,
  cd_machine varchar, cd_category varchar, cd_subcategory varchar, change_over bool, planned_downtime bool,
  ts_end timestamptz, duration int4, id_enterprise int4, desc_category varchar, desc_subcategory varchar,
  cd_category_client int4, cd_subcategory_client int4, last_update timestamptz, ignore_cost bool)
WHERE f1.ts_event < (SELECT boundary FROM _evt_fence)   -- deep-history slice only
ON CONFLICT (id_equipment, ts_event) DO NOTHING;

-- ---------------------------------------------------------------------------
-- D. equipment_events_man  (manual/operator-edited events). Same natural PK.
-- ---------------------------------------------------------------------------
INSERT INTO equipment_events_man (
  id_equipment, ts_event, status, id_equipment_event, txt_downtime_notes, idle, idle_processed,
  forced_creation_system, fault, fault_processed, cd_machine, cd_category, cd_subcategory, change_over,
  planned_downtime, ts_end, duration, id_enterprise, desc_category, desc_subcategory, cd_category_client,
  cd_subcategory_client, last_update, ignore_cost)
SELECT
  f1.id_equipment, f1.ts_event, f1.status, f1.id_equipment_event, f1.txt_downtime_notes, f1.idle,
  f1.idle_processed, f1.forced_creation_system, f1.fault, f1.fault_processed, f1.cd_machine, f1.cd_category,
  f1.cd_subcategory, f1.change_over, f1.planned_downtime, f1.ts_end, f1.duration, f1.id_enterprise,
  f1.desc_category, f1.desc_subcategory, f1.cd_category_client, f1.cd_subcategory_client, f1.last_update,
  f1.ignore_cost
FROM dblink('f1src', $q$
  SELECT id_equipment, ts_event, status, id_equipment_event, txt_downtime_notes, idle, idle_processed,
         forced_creation_system, fault, fault_processed, cd_machine, cd_category, cd_subcategory, change_over,
         planned_downtime, ts_end, duration, id_enterprise, desc_category, desc_subcategory, cd_category_client,
         cd_subcategory_client, last_update, ignore_cost
  FROM equipment_events_man WHERE id_enterprise = 3
$q$) AS f1(
  id_equipment int4, ts_event timestamptz, status int4, id_equipment_event int8, txt_downtime_notes varchar,
  idle varchar, idle_processed bool, forced_creation_system bool, fault int4, fault_processed bool,
  cd_machine varchar, cd_category varchar, cd_subcategory varchar, change_over bool, planned_downtime bool,
  ts_end timestamptz, duration int4, id_enterprise int4, desc_category varchar, desc_subcategory varchar,
  cd_category_client int4, cd_subcategory_client int4, last_update timestamptz, ignore_cost bool)
WHERE f1.ts_event < (SELECT boundary FROM _evt_fence)   -- deep-history slice only
ON CONFLICT (id_equipment, ts_event) DO NOTHING;

-- ---------------------------------------------------------------------------
-- E. user_logs  (audit trail). id_user_logs is a plain serial (nextval), NOT a
--    natural key -> insert with fresh PK, dedup by business tuple so re-runs add
--    nothing. F1's whole range is strictly before F3's earliest, so first run
--    adds all history with zero overlap.
-- ---------------------------------------------------------------------------
INSERT INTO user_logs (
  ts_event, id_enterprise, id_site, id_area, id_equipment, nm_user, cd_user,
  category, subcategory, description, ts_log, ip, payload)
SELECT
  f1.ts_event, f1.id_enterprise, f1.id_site, f1.id_area, f1.id_equipment, f1.nm_user, f1.cd_user,
  f1.category, f1.subcategory, f1.description, f1.ts_log, f1.ip, f1.payload
FROM dblink('f1src', $q$
  SELECT ts_event, id_enterprise, id_site, id_area, id_equipment, nm_user, cd_user,
         category, subcategory, description, ts_log, ip, payload
  FROM user_logs WHERE id_enterprise = 3
$q$) AS f1(
  ts_event timestamptz, id_enterprise int4, id_site int4, id_area int4, id_equipment int4, nm_user varchar,
  cd_user int4, category varchar, subcategory varchar, description text, ts_log timestamptz, ip varchar,
  payload jsonb)
WHERE NOT EXISTS (
  SELECT 1 FROM user_logs u
  WHERE u.id_enterprise = f1.id_enterprise
    AND u.ts_event      = f1.ts_event
    AND u.cd_user IS NOT DISTINCT FROM f1.cd_user
    AND u.category IS NOT DISTINCT FROM f1.category
    AND u.description IS NOT DISTINCT FROM f1.description);

-- ---------------------------------------------------------------------------
-- F. equipment_runtime_shift  (the shift grain that GATES v_report_downtimes).
--    Natural PK (id_equipment, ts_value) -> ON CONFLICT DO NOTHING. Fenced to
--    the pre-cutover deep-history slice. recalc_needed=false; OEE clamped
--    NULL-preserving (deep slice is already in-domain, clamp is belt-and-braces).
--    Fresh serial id_runtime_shift. This is what makes deep-history downtimes
--    SURFACE in the report with their op.
-- ---------------------------------------------------------------------------
INSERT INTO equipment_runtime_shift (
  ts_value, id_equipment, oee, recalc_needed, oee_p, oee_a, oee_q, available_time, running_time,
  stopped_time, planned_downtime, ideal_production, idle_time, idle_starved, idle_blocked, id_shift,
  id_shift_hour, id_team, duration, ts_range, gross, net, downtime, changeover_time, target, ts_end,
  manually_customized, invalidated, scrap, speed, cd_shift, ts_value_production, target_customized,
  proportional_target, ideal_speed, computed_at, source_watermark)
SELECT
  f1.ts_value, f1.id_equipment,
  CASE WHEN f1.oee   IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee))   END,
  false AS recalc_needed,
  CASE WHEN f1.oee_p IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee_p)) END,
  CASE WHEN f1.oee_a IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee_a)) END,
  CASE WHEN f1.oee_q IS NULL THEN NULL ELSE GREATEST(0::float4, LEAST(1::float4, f1.oee_q)) END,
  f1.available_time, f1.running_time, f1.stopped_time, f1.planned_downtime, f1.ideal_production,
  f1.idle_time, f1.idle_starved, f1.idle_blocked, f1.id_shift, f1.id_shift_hour, f1.id_team, f1.duration,
  f1.ts_range, f1.gross, f1.net, f1.downtime, f1.changeover_time, f1.target, f1.ts_end,
  f1.manually_customized, f1.invalidated, f1.scrap, f1.speed, f1.cd_shift, f1.ts_value_production,
  f1.target_customized, f1.proportional_target, f1.ideal_speed, f1.computed_at, f1.source_watermark
FROM dblink('f1src', $q$
  SELECT s.ts_value, s.id_equipment, s.oee, s.oee_p, s.oee_a, s.oee_q, s.available_time, s.running_time,
         s.stopped_time, s.planned_downtime, s.ideal_production, s.idle_time, s.idle_starved, s.idle_blocked,
         s.id_shift, s.id_shift_hour, s.id_team, s.duration, s.ts_range, s.gross, s.net, s.downtime,
         s.changeover_time, s.target, s.ts_end, s.manually_customized, s.invalidated, s.scrap, s.speed,
         s.cd_shift, s.ts_value_production, s.target_customized, s.proportional_target, s.ideal_speed,
         s.computed_at, s.source_watermark
  FROM equipment_runtime_shift s
  JOIN equipments e ON e.id_equipment = s.id_equipment AND e.id_enterprise = 3
$q$
) AS f1(
  ts_value timestamptz, id_equipment int4, oee float4, oee_p float4, oee_a float4, oee_q float4,
  available_time int4, running_time int4, stopped_time int4, planned_downtime int4, ideal_production float8,
  idle_time int4, idle_starved int4, idle_blocked int4, id_shift int4, id_shift_hour int4, id_team int4,
  duration int4, ts_range tstzrange, gross float4, net float4, downtime int4, changeover_time int4,
  target float8, ts_end timestamptz, manually_customized bool, invalidated bool, scrap float4, speed float4,
  cd_shift varchar, ts_value_production date, target_customized bool, proportional_target float4,
  ideal_speed float8, computed_at timestamptz, source_watermark timestamptz)
WHERE f1.ts_value < (SELECT boundary FROM _shift_fence)
ON CONFLICT (id_equipment, ts_value) DO NOTHING;

-- ---------------------------------------------------------------------------
-- VERIFICATION (before vs after, dup checks, op-fix)
-- ---------------------------------------------------------------------------
SELECT 'AFTER counts' AS section,
  (SELECT count(*) FROM production_orders WHERE id_enterprise=3)                     AS po,
  (SELECT count(*) FROM _new_po)                                                     AS po_new,
  (SELECT count(*) FROM production_orders_runtime por
       JOIN production_orders po ON po.id_production_order=por.id_production_order
     WHERE po.id_enterprise=3)                                                       AS runtime,
  (SELECT count(*) FROM equipment_events WHERE id_enterprise=3)                      AS events,
  (SELECT count(*) FROM equipment_events_man WHERE id_enterprise=3)                  AS events_man,
  (SELECT count(*) FROM user_logs WHERE id_enterprise=3)                             AS user_logs,
  (SELECT count(*) FROM equipment_runtime_shift s
       JOIN equipments e ON e.id_equipment=s.id_equipment AND e.id_enterprise=3)     AS runtime_shift;

SELECT 'BEFORE counts' AS section, * FROM _before;

-- Dup check: business key must remain unique (0 rows) — the crux safety gate.
SELECT 'DUP po (id_enterprise,id_order)' AS check, count(*) AS violations FROM (
  SELECT id_enterprise, id_order FROM production_orders WHERE id_enterprise=3
  GROUP BY 1,2 HAVING count(*) > 1) d;

-- Dup check: events natural key.
SELECT 'DUP events (id_equipment,ts_event)' AS check, count(*) AS violations FROM (
  SELECT id_equipment, ts_event FROM equipment_events WHERE id_enterprise=3
  GROUP BY 1,2 HAVING count(*) > 1) d;

-- Dangling runtime (must be 0): every runtime row resolves to a PO.
SELECT 'DANGLING runtime rows (ent3 equip)' AS check, count(*) AS violations
FROM production_orders_runtime por
JOIN equipments e ON e.id_equipment=por.id_equipment AND e.id_enterprise=3
LEFT JOIN production_orders po ON po.id_production_order=por.id_production_order
WHERE po.id_production_order IS NULL;

-- op-fix: v_report_downtimes op populated for ent-3.
SELECT 'v_report_downtimes op' AS section, (op IS NULL) AS op_is_null, count(*),
       min(inicio) AS min_ts, max(inicio) AS max_ts
FROM v_report_downtimes WHERE id_enterprise=3 GROUP BY (op IS NULL) ORDER BY 2;

-- op-fix drilldown: the newly-bridged POs now expose their order number.
SELECT v.op, v.linha, count(*) AS downtime_rows,
       min(v.inicio) AS first_dt, max(v.inicio) AS last_dt
FROM v_report_downtimes v
JOIN _new_po np ON np.id_order = v.op
WHERE v.id_enterprise=3
GROUP BY v.op, v.linha ORDER BY v.op;

\if :dryrun
  \echo '>>> DRY RUN — rolling back.'
  ROLLBACK;
\else
  \echo '>>> LIVE — committing.'
  COMMIT;
\endif
