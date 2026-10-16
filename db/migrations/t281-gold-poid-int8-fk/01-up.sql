-- t281 — gold.production_orders_runtime.id_production_order : int4 -> int8  + add missing FK
--        (closes GAP-9 of docs/clients/bispharma-production-readiness-punchlist.md)
--
-- WHY (task GAP-9)
-- ────────────────
-- core.production_orders.id_production_order is the PRIMARY KEY and is `bigint` (int8).
-- gold.production_orders_runtime.id_production_order (one OEE/production row per PO RUN)
-- carries the SAME id but was declared `integer` (int4). Two concrete problems:
--   1. TYPE MISMATCH across the FK relationship. Joins runtime⋈PO work today only because
--      every live id is < 2^31 (current max = 2,025,144 in BOTH tables, verified live), but
--      the PO surrogate is an int8 sequence — once it crosses 2,147,483,647 the child column
--      silently overflows / int4-int8 join comparisons stop being able to represent the value.
--   2. NO referential integrity. There is currently no FK from runtime.id_production_order ->
--      core.production_orders(id_production_order). A runtime row can point at a non-existent
--      PO. Verified live: 0 orphans today, so the FK VALIDATEs cleanly.
--
-- WHAT
-- ────
--   * widen gold.production_orders_runtime.id_production_order int4 -> int8 (matches parent PK)
--   * add production_orders_runtime_id_production_order_fkey (NOT VALID then VALIDATE; 0 orphans)
--
-- The column is referenced by 4 VIEWS which block ALTER COLUMN ... TYPE, so they are dropped
-- and recreated verbatim in the SAME transaction (bodies captured live via
-- pg_get_viewdef(...,true); the bodies do NOT change with the column type). Verified live:
-- NOTHING else depends on these 4 views (0 rewrite deps), so a plain DROP (no CASCADE) is safe.
-- Owner / grants / security_invoker / COMMENT are all restored to their captured state:
--   - bi.production_order_runtime      : owner bi_owner, DEFINER (no security_invoker)
--   - serving.v_events_2               : owner postgres, security_invoker=on
--   - serving.v_operator_po_details_3  : owner postgres, security_invoker=on
--   - serving.v_report_downtimes       : owner postgres, security_invoker=on
--
-- The DB default search_path (gold, silver, bronze, identity, config, ops, serving,
-- customer_reports, core, public) is set explicitly below so the bare table names inside the
-- view bodies re-resolve to the SAME objects they resolve to today (equipment_* -> silver,
-- equipment_oee_shift/production_orders_runtime -> gold, production_orders/equipments/areas/
-- sites/clients -> core). `bi` is intentionally NOT on the path (matches DB default).
--
-- The id_production_order column COMMENT ("FK -> production_orders...") already exists and
-- survives ALTER COLUMN ... TYPE (it is not a view comment); no need to re-assert it.
--
-- SAFETY. lock_timeout=5s guards the brief ACCESS EXCLUSIVE table rewrite (18,889 rows rewrite
-- in ms); if a long txn holds a conflicting lock the migration ABORTS rather than queues.
-- Fully reversible: rollback.sql narrows back to int4 (safe while max < 2^31) and restores the
-- views identically.

BEGIN;

SET lock_timeout = '5s';
SET search_path = gold, silver, bronze, identity, config, ops, serving, customer_reports, core, public;

-- ── 1. drop the 4 blocking views (no interdependencies, 0 external dependents — verified) ──
DROP VIEW bi.production_order_runtime;
DROP VIEW serving.v_events_2;
DROP VIEW serving.v_operator_po_details_3;
DROP VIEW serving.v_report_downtimes;

-- ── 2. widen the child column to match the parent PK (bigint) ──
ALTER TABLE gold.production_orders_runtime
  ALTER COLUMN id_production_order TYPE bigint;

-- ── 3. recreate the 4 views verbatim, restoring owner/grants/security_invoker/comment ──

-- 3a. bi.production_order_runtime  (owner bi_owner, DEFINER semantics; bi NOT in search_path)
--     Created as postgres (bi_owner lacks USAGE on schemas gold/core, so it cannot RESOLVE the
--     bare names at parse time — it only holds table-level SELECT, which suffices at runtime via
--     the stored OID). Ownership is then transferred to bi_owner and the extra grants are issued
--     UNDER the bi_owner role so the grantor matches the captured relacl exactly.
CREATE VIEW bi.production_order_runtime AS
 SELECT eq.id_enterprise,
    por.id_production_order,
    por.id_equipment,
    por.oee,
    por.oee_a,
    por.oee_p,
    por.oee_q,
    por.gross_production,
    por.net_production,
    por.running_time,
    lower(por.runtime_timerange) AS ts_start,
    upper(por.runtime_timerange) AS ts_end
   FROM production_orders_runtime por
     JOIN equipments eq ON eq.id_equipment = por.id_equipment;
ALTER VIEW bi.production_order_runtime OWNER TO bi_owner;
SET LOCAL ROLE bi_owner;
GRANT SELECT ON bi.production_order_runtime TO superset_ro, cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON bi.production_order_runtime TO cloudbeaver_rw;
RESET ROLE;
COMMENT ON VIEW bi.production_order_runtime IS 'bi (Superset): one row per PO runtime segment (OEE decomposition, gross/net, running_time, runtime range). Tenant fence external.';

-- 3b. serving.v_events_2  (owner postgres, security_invoker=on)
CREATE VIEW serving.v_events_2 AS
 SELECT 1 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    COALESCE(ppe.id_equipment, pe.id_equipment, e.id_equipment) AS id_equipment,
    COALESCE(ppe.nm_equipment, pe.nm_equipment, e.nm_equipment) AS nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    ee.txt_downtime_notes,
    ee.cd_machine,
    ee.cd_category,
    ee.cd_subcategory,
    ee.change_over,
    ee.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_events ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     LEFT JOIN equipments pe ON pe.id_equipment = e.id_parentequipment
     LEFT JOIN equipments ppe ON ppe.id_equipment = pe.id_parentequipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
  WHERE (ee.duration >= COALESCE(e.stop_threshold_time, 0) OR ee.ts_end IS NULL) AND ee.status <> 6 AND e.event_should_be_displayed = true
UNION
 SELECT 2 AS event_type,
    eem.ts_event AS ts_timeline,
    eem.ts_event,
    eem.ts_end,
    date_part('epoch'::text, eem.ts_end - eem.ts_event)::integer AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    eem.txt_downtime_notes,
    eem.cd_machine,
    eem.cd_category,
    eem.cd_subcategory,
    eem.change_over,
    eem.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_events_man eem
     JOIN equipments e ON eem.id_equipment_event = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
UNION
 SELECT 3 AS event_type,
    ee.ts_event AS ts_timeline,
    ee.ts_event,
    ee.ts_end,
    ee.duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    ee.txt_downtime_notes,
    ee.cd_machine,
    ee.cd_category,
    ee.cd_subcategory,
    ee.change_over,
    ee.status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_events_low_speed ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
  WHERE (ee.duration >= COALESCE(e.stop_threshold_time, 0) OR ee.ts_end IS NULL) AND ee.status <> 6 AND e.event_should_be_displayed = true
UNION
 SELECT 4 AS event_type,
    lower(ee.runtime_timerange) AS ts_timeline,
    lower(ee.runtime_timerange) AS ts_event,
    upper(ee.runtime_timerange) AS ts_end,
        CASE
            WHEN upper(ee.runtime_timerange) IS NOT NULL THEN date_part('epoch'::text, upper(ee.runtime_timerange) - lower(ee.runtime_timerange))::integer
            ELSE NULL::integer
        END AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    COALESCE(po.id_order_text, po.id_order::character varying) AS id_order,
    c.nm_client
   FROM production_orders_runtime ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN production_orders po USING (id_production_order)
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
     LEFT JOIN clients c USING (id_client)
UNION
 SELECT 5 AS event_type,
    upper(ee.runtime_timerange) AS ts_timeline,
    lower(ee.runtime_timerange) AS ts_event,
    upper(ee.runtime_timerange) AS ts_end,
        CASE
            WHEN upper(ee.runtime_timerange) IS NOT NULL THEN date_part('epoch'::text, upper(ee.runtime_timerange) - lower(ee.runtime_timerange))::integer
            ELSE NULL::integer
        END AS duration,
    e.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    COALESCE(po.id_order_text, po.id_order::character varying) AS id_order,
    c.nm_client
   FROM production_orders_runtime ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
     JOIN production_orders po USING (id_production_order)
     LEFT JOIN clients c USING (id_client)
  WHERE upper(ee.runtime_timerange) IS NOT NULL
UNION
 SELECT 6 AS event_type,
    ee.ts_value AS ts_timeline,
    ee.ts_value AS ts_event,
    ee.ts_end,
    ee.duration,
    ee.id_equipment,
    e.nm_equipment,
    a.nm_area,
    s.nm_site,
    e.id_enterprise,
    NULL::character varying AS txt_downtime_notes,
    NULL::character varying AS cd_machine,
    NULL::character varying AS cd_category,
    NULL::character varying AS cd_subcategory,
    NULL::boolean AS change_over,
    NULL::integer AS status,
    NULL::character varying AS id_order,
    NULL::character varying AS nm_client
   FROM equipment_oee_shift ee
     JOIN equipments e ON ee.id_equipment = e.id_equipment
     JOIN areas a ON e.id_area = a.id_area
     JOIN sites s ON e.id_site = s.id_site
  WHERE ee.ts_value < now();
ALTER VIEW serving.v_events_2 SET (security_invoker = on);
GRANT SELECT ON serving.v_events_2 TO superset_ro, bi_owner, cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON serving.v_events_2 TO cloudbeaver_rw;
COMMENT ON VIEW serving.v_events_2 IS 'serving: unified event timeline (downtimes + PO/plc events) resolving id_equipment across parent/child event tables. Backing view for event-timeline reads.';

-- 3c. serving.v_operator_po_details_3  (owner postgres, security_invoker=on)
CREATE VIEW serving.v_operator_po_details_3 AS
 SELECT base.id_production_order,
    base.id_equipment,
    base.id_enterprise,
    base.net_production,
    base.scrap,
    base.running_time,
    base.downtime,
    base.net_production + base.scrap AS gross
   FROM ( SELECT po.id_production_order,
            po.id_equipment,
            po.id_enterprise,
            po.ts_start,
            po.ts_end,
            COALESCE(NULLIF(sum(por.net_production), 0::double precision), (( SELECT COALESCE(sum(ev.net_production_incr), 0::real) AS "coalesce"
                   FROM equipment_values ev
                  WHERE ev.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ev.ts_value >= po.ts_start AND (po.ts_end IS NULL OR ev.ts_value <= po.ts_end)))::double precision, 0::double precision) AS net_production,
            COALESCE(NULLIF(sum(COALESCE(por.gross_production, 0::double precision) - COALESCE(por.net_production, 0::double precision)), 0::double precision), 0::double precision) AS scrap,
            COALESCE(sum(EXTRACT(epoch FROM COALESCE(upper(por.runtime_timerange), now()) - lower(por.runtime_timerange))), 0::numeric)::integer AS running_time,
            COALESCE(( SELECT sum(
                        CASE
                            WHEN ee.ts_end IS NULL THEN GREATEST(0, EXTRACT(epoch FROM now() - ee.ts_event)::integer)
                            ELSE COALESCE(ee.duration, 0)
                        END) AS sum
                   FROM equipment_events ee
                  WHERE ee.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ee.ts_event >= po.ts_start AND (po.ts_end IS NULL OR ee.ts_event <= po.ts_end) AND ee.status <> 6 AND ee.forced_creation_system = false), 0::bigint)::integer AS downtime
           FROM production_orders po
             LEFT JOIN production_orders_runtime por ON por.id_production_order = po.id_production_order
          WHERE po.status = ANY (ARRAY[1, 2, 4])
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, po.ts_start, po.ts_end) base;
ALTER VIEW serving.v_operator_po_details_3 SET (security_invoker = on);
GRANT SELECT ON serving.v_operator_po_details_3 TO cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON serving.v_operator_po_details_3 TO cloudbeaver_rw;
COMMENT ON VIEW serving.v_operator_po_details_3 IS 'serving: operator-app production-order detail (net_production/scrap/running_time/downtime + derived rates) for one PO. Read by read-api /v1/operator-po-details.';

-- 3d. serving.v_report_downtimes  (owner postgres, security_invoker=on)
CREATE VIEW serving.v_report_downtimes AS
 SELECT po.id_order AS op,
    e.nm_equipment AS linha,
    shift.cd_shift AS turno,
    eventos.ts_event AS inicio,
    eventos.ts_end AS fim,
    eventos.duration AS duracao,
    eventos.cd_machine AS maquina,
    eventos.cd_category AS codigo_categoria,
    eventos.cd_subcategory AS codigo_subcategoria,
    eventos.desc_category AS descricao_categoria,
    eventos.desc_subcategory AS descricao_subcategoria,
    eventos.txt_downtime_notes AS anotacao,
    eventos.id_enterprise,
    shift.ts_value
   FROM ( SELECT equipment_events.id_equipment,
            equipment_events.ts_event,
            equipment_events.status,
            equipment_events.id_equipment_event,
            equipment_events.txt_downtime_notes,
            equipment_events.idle,
            equipment_events.idle_processed,
            equipment_events.forced_creation_system,
            equipment_events.fault,
            equipment_events.fault_processed,
            equipment_events.cd_machine,
            equipment_events.cd_category,
            equipment_events.cd_subcategory,
            equipment_events.change_over,
            equipment_events.planned_downtime,
            equipment_events.ts_end,
            equipment_events.duration,
            equipment_events.id_enterprise,
            equipment_events.desc_category,
            equipment_events.desc_subcategory,
            equipment_events.cd_category_client,
            equipment_events.cd_subcategory_client,
            equipment_events.last_update,
            equipment_events.ignore_cost
           FROM equipment_events
        UNION ALL
         SELECT equipment_events_man.id_equipment,
            equipment_events_man.ts_event,
            equipment_events_man.status,
            equipment_events_man.id_equipment_event,
            equipment_events_man.txt_downtime_notes,
            equipment_events_man.idle,
            equipment_events_man.idle_processed,
            equipment_events_man.forced_creation_system,
            equipment_events_man.fault,
            equipment_events_man.fault_processed,
            equipment_events_man.cd_machine,
            equipment_events_man.cd_category,
            equipment_events_man.cd_subcategory,
            equipment_events_man.change_over,
            equipment_events_man.planned_downtime,
            equipment_events_man.ts_end,
            equipment_events_man.duration,
            equipment_events_man.id_enterprise,
            equipment_events_man.desc_category,
            equipment_events_man.desc_subcategory,
            equipment_events_man.cd_category_client,
            equipment_events_man.cd_subcategory_client,
            equipment_events_man.last_update,
            equipment_events_man.ignore_cost
           FROM equipment_events_man) eventos
     JOIN equipment_oee_shift shift ON eventos.id_equipment = shift.id_equipment
     JOIN equipments e ON eventos.id_equipment = e.id_equipment
     LEFT JOIN production_orders_runtime por ON por.id_equipment = eventos.id_equipment AND por.runtime_timerange @> eventos.ts_event
     LEFT JOIN production_orders po ON po.id_production_order = por.id_production_order
  WHERE eventos.status = 10 AND e.event_should_be_displayed = true AND eventos.ts_event >= lower(shift.ts_range) AND eventos.ts_event <= upper(shift.ts_range) AND eventos.duration >= COALESCE(e.stop_threshold_time, 0);
ALTER VIEW serving.v_report_downtimes SET (security_invoker = on);
GRANT SELECT ON serving.v_report_downtimes TO cloudbeaver_ro, readapi_ro;
GRANT SELECT, INSERT, UPDATE, DELETE ON serving.v_report_downtimes TO cloudbeaver_rw;
COMMENT ON VIEW serving.v_report_downtimes IS 'serving: DBA-owned tenant-carrying downtime report view (UNION+joins), keyed by SHIFT begin (ts_value = shift begin, NOT event ts). Read by read-api report-downtimes (tenant-custom).';

-- ── 4. add the missing FK (NOT VALID then VALIDATE; 0 orphans verified live) ──
ALTER TABLE gold.production_orders_runtime
  ADD CONSTRAINT production_orders_runtime_id_production_order_fkey
  FOREIGN KEY (id_production_order) REFERENCES core.production_orders(id_production_order) NOT VALID;
ALTER TABLE gold.production_orders_runtime
  VALIDATE CONSTRAINT production_orders_runtime_id_production_order_fkey;

COMMIT;
