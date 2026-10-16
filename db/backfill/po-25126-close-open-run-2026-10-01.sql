-- 2026-10-01: PO 25126 (ent 2, test tenant) is finished (status 3, ts_end 2026-08-16 21:07:02) but its runtime
-- row was left OPEN → re-flagged every pass, header re-flagged by propagate, never drainable (ping-pong with the
-- stranded sweep). Close the run at the header's ts_end, like the normal stop path does.
SET lock_timeout = '10s';
BEGIN;
CREATE TABLE IF NOT EXISTS ops._bkp_po_25126_open_run_20261001 AS SELECT r.* FROM gold.production_orders_runtime r WHERE r.id_production_order = 25126;
UPDATE gold.production_orders_runtime r
   SET runtime_timerange = tstzrange(lower(r.runtime_timerange), p.ts_end), recalc_needed = false, last_update = now()
  FROM core.production_orders p
 WHERE p.id_production_order = r.id_production_order AND r.id_production_order = 25126
   AND upper(r.runtime_timerange) IS NULL AND p.status = 3 AND p.ts_end > lower(r.runtime_timerange)
RETURNING r.id_production_order_runtime, r.runtime_timerange;
UPDATE core.production_orders SET recalc_needed = false WHERE id_production_order = 25126 RETURNING id_production_order;
COMMIT;
-- any other finished PO with an open run? (must be 0)
SELECT 'finished_with_open_run', count(*) FROM gold.production_orders_runtime r JOIN core.production_orders p USING (id_production_order) WHERE upper(r.runtime_timerange) IS NULL AND p.status IN (3, 4);
