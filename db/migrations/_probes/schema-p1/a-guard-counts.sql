-- schema-p1 probe (a): will the three schema-p1 migrations' guards pass? READ-ONLY, counts/aggregates only.
-- Run against packiot_analytics BEFORE applying:
--   t-data-sync-po-start-date, t-po-runtime-exclusion-not-null-fk, t-equipments-self-fks
-- Output: label|value…; the value each guard needs is in the label. Small tables (283 equipments, ~57k runtimes,
-- ~63k POs) — no hypertable scans here.
\set ON_ERROR_STOP 1
SET default_transaction_read_only = on;
SET statement_timeout = '60s';
SET lock_timeout = '2s';

-- ===================== 1. t-data-sync-po-start-date =====================
SELECT 'M1.1 live serving.data_sync is the t244c body (guard needs t)',
       position('customer_reports.shift rse' IN prosrc) > 0
       AND position('coalesce(po.ts_start_tz,po.last_update,eqvs.ts_creation)' IN prosrc) > 0
  FROM pg_proc WHERE oid = to_regprocedure('serving.data_sync(integer, integer)');
SELECT 'M1.2 already migrated (expect f before apply)',
       position('coalesce(po.ts_start,po.last_update,eqvs.ts_creation)' IN prosrc) > 0
  FROM pg_proc WHERE oid = to_regprocedure('serving.data_sync(integer, integer)');
SELECT 'M1.3 serving.data_sync has a function-level SET (expect empty)', coalesce(array_to_string(proconfig, ','), '')
  FROM pg_proc WHERE oid = to_regprocedure('serving.data_sync(integer, integer)');
-- every in-DB object still mentioning the *_tz columns (object names only) — what the later drop step must clear
SELECT 'M1.4 functions mentioning ts_start_tz/ts_end_tz: count|names (expect 1|serving.data_sync before, 0 after)',
       count(*), coalesce(string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY 1), '')
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND p.prosrc ~ 'ts_(start|end)_tz';
SELECT 'M1.5 views depending on production_orders.ts_start_tz/ts_end_tz (expect 0)', count(DISTINCT r.ev_class)
  FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid
  JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
 WHERE d.refobjid = 'core.production_orders'::regclass AND a.attname IN ('ts_start_tz', 'ts_end_tz')
   AND r.ev_class <> 'core.production_orders'::regclass;
SELECT 'M1.6 POs by status: status|total|ts_start_tz set|ts_end_tz set|ts_start set (tz columns expected 0)',
       status, count(*), count(ts_start_tz), count(ts_end_tz), count(ts_start)
  FROM core.production_orders GROUP BY status ORDER BY status;
-- business impact: non-running POs in the data_sync join window (last_update >= now()-5 months) whose UpdatedDate moves
SELECT 'M1.7 non-running POs in the 5-month window whose UpdatedDate changes (ts_start set and <> last_update), per tenant',
       id_enterprise, count(*) FILTER (WHERE ts_start IS NOT NULL AND ts_start IS DISTINCT FROM last_update),
       count(*), round(avg(EXTRACT(epoch FROM last_update - ts_start) / 86400) FILTER (WHERE ts_start IS NOT NULL)::numeric, 1) AS avg_days_shift
  FROM core.production_orders
 WHERE status <> 2 AND last_update >= now() - interval '5 month'
 GROUP BY id_enterprise ORDER BY id_enterprise;

-- ===================== 2. t-po-runtime-exclusion-not-null-fk =====================
SELECT 'M2.1 runtimes with NULL id_equipment|NULL runtime_timerange|orphan id_equipment (guard needs 0|0|0)',
       count(*) FILTER (WHERE r.id_equipment IS NULL),
       count(*) FILTER (WHERE r.runtime_timerange IS NULL),
       count(*) FILTER (WHERE r.id_equipment IS NOT NULL AND e.id_equipment IS NULL)
  FROM gold.production_orders_runtime r LEFT JOIN core.equipments e ON e.id_equipment = r.id_equipment;
-- informational: an EMPTY range is also invisible to the EXCLUDE ('empty' && x is false); mirror-worker's
-- GREATEST(seal, lower) clamp produces one when seal < lower. Not guarded by the migration.
SELECT 'M2.2 runtimes with an empty runtime_timerange (informational)', count(*)
  FROM gold.production_orders_runtime WHERE isempty(runtime_timerange);
SELECT 'M2.3 runtime id_equipment differs from its PO''s id_equipment (informational; concurrent-split allows it)', count(*)
  FROM gold.production_orders_runtime r JOIN core.production_orders po USING (id_production_order)
 WHERE r.id_equipment IS DISTINCT FROM po.id_equipment;
SELECT 'M2.4 existing constraints on the runtime table (expect no *_nn, no id_equipment fkey yet)', conname, contype
  FROM pg_constraint WHERE conrelid = 'gold.production_orders_runtime'::regclass ORDER BY conname;

-- ===================== 3. t-equipments-self-fks =====================
SELECT 'M3.1 per column: set|orphans (guard needs 0)|value 0|self-ref|points to another tenant|points to inactive',
       c.col,
       count(c.v),
       count(*) FILTER (WHERE c.v IS NOT NULL AND t.id_equipment IS NULL),
       count(*) FILTER (WHERE c.v = 0),
       count(*) FILTER (WHERE c.v = e.id_equipment),
       count(*) FILTER (WHERE t.id_equipment IS NOT NULL AND t.id_enterprise IS DISTINCT FROM e.id_enterprise),
       count(*) FILTER (WHERE t.id_equipment IS NOT NULL AND NOT t.active)
  FROM core.equipments e
  CROSS JOIN LATERAL (VALUES ('lead_machine', e.lead_machine::bigint), ('gross_machine', e.gross_machine),
                             ('scrap_machine', e.scrap_machine), ('net_machine', e.net_machine),
                             ('id_parentequipment', e.id_parentequipment::bigint)) AS c(col, v)
  LEFT JOIN core.equipments t ON t.id_equipment = c.v
 GROUP BY c.col ORDER BY c.col;
SELECT 'M3.2 cross-tenant refs by tenant|column|rows (no rows printed = none; sandbox twin ids only expected mid-heal)', e.id_enterprise, c.col, count(*)
  FROM core.equipments e
  CROSS JOIN LATERAL (VALUES ('lead_machine', e.lead_machine::bigint), ('gross_machine', e.gross_machine),
                             ('scrap_machine', e.scrap_machine), ('net_machine', e.net_machine),
                             ('id_parentequipment', e.id_parentequipment::bigint)) AS c(col, v)
  JOIN core.equipments t ON t.id_equipment = c.v
 WHERE t.id_enterprise IS DISTINCT FROM e.id_enterprise
 GROUP BY 2, 3 ORDER BY 2, 3;
SELECT 'M3.3 self-FKs on core.equipments (expect equipments_id_equipment_foreign + equipments_net_machine_fkey)', conname,
       pg_get_constraintdef(oid)
  FROM pg_constraint WHERE conrelid = 'core.equipments'::regclass AND contype = 'f' AND confrelid = conrelid ORDER BY conname;
SELECT 'M3.4 column types lead|gross|scrap|net|parent|PK (expect integer|bigint|bigint|bigint|integer|integer)',
       format_type(max(atttypid) FILTER (WHERE attname = 'lead_machine'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'gross_machine'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'scrap_machine'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'net_machine'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'id_parentequipment'), NULL),
       format_type(max(atttypid) FILTER (WHERE attname = 'id_equipment'), NULL)
  FROM pg_attribute WHERE attrelid = 'core.equipments'::regclass AND attnum > 0 AND NOT attisdropped;
-- lock contention preview: who holds locks on the two tables right now (counts by mode)
SELECT 'M3.5 current locks on core.equipments / gold.production_orders_runtime (relation|mode|granted|n)',
       c.relname, l.mode, l.granted, count(*)
  FROM pg_locks l JOIN pg_class c ON c.oid = l.relation
 WHERE l.relation IN ('core.equipments'::regclass, 'gold.production_orders_runtime'::regclass)
 GROUP BY 2, 3, 4 ORDER BY 2, 3, 4;
