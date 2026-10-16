-- t253 part 2 — backfill the EXISTING production_orders_runtime rows whose running_time
-- already overflowed (the compute.go LEAST bound in 01 prevents NEW overflow, but old rows
-- outside the recompute window won't self-heal). Applies the SAME physical invariant
-- (running_time ≤ PO wall-clock span) directly to stored CPACK rows. Only ever LOWERS an
-- already-impossible value; no-op on clean rows. Not a DQ clamp — it corrects data the
-- now-fixed computation could never produce.
BEGIN;
SET LOCAL lock_timeout = '25s';
UPDATE gold.production_orders_runtime r
   SET running_time = LEAST(r.running_time,
         GREATEST(extract(epoch FROM (COALESCE(upper(r.runtime_timerange), now()) - lower(r.runtime_timerange))), 0)::int)
  FROM core.equipments e
 WHERE e.id_equipment = r.id_equipment AND e.id_enterprise = 3
   AND r.running_time > GREATEST(extract(epoch FROM (COALESCE(upper(r.runtime_timerange), now()) - lower(r.runtime_timerange))), 60) * 1.05;
COMMIT;
