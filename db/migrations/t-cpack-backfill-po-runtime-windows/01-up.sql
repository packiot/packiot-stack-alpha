-- t-cpack-backfill-po-runtime-windows — recover runtime windows dropped by the
-- replicator OrderStarted equipment-gate bug (code fix: PR #1389).
--
-- HARDPROOF (CPACK ent3 vs legacy packiot40): 651/1120 POs (58%) had ts_start but no
-- gold.production_orders_runtime row — legacy had all of them, raw intact in silver/
-- historian, 0 in the DLQ. The window is the ONLY thing missing; once it exists,
-- compute.go attributes the raw production (recalc_needed=true). This creates a
-- [ts_start, ts_end) window for every such PO. POs whose raw is still in silver
-- (post-retention-cut, ~Jul-23 on) recover immediately; older POs get a zeroed window
-- now and are filled by the historian backfill.
--
-- The exclusion constraint (a machine can't run two POs at once) is respected: the
-- loop inserts oldest-first and skips any window that overlaps an already-present one
-- (a data-quality residue), catching exclusion_violation defensively.
DO $$
DECLARE r record; n int := 0;
BEGIN
  FOR r IN
    SELECT po.id_production_order AS po, po.id_equipment AS eq,
           po.ts_start AS lo, COALESCE(po.ts_end, now()) AS hi
      FROM core.production_orders po
     WHERE po.id_enterprise = 3
       AND po.status >= 2
       AND po.ts_start IS NOT NULL
       AND po.id_equipment IS NOT NULL
       AND COALESCE(po.ts_end, now()) > po.ts_start
       AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime x
                        WHERE x.id_production_order = po.id_production_order)
     ORDER BY po.id_equipment, po.ts_start
  LOOP
    BEGIN
      INSERT INTO gold.production_orders_runtime
             (id_production_order, id_equipment, runtime_timerange, recalc_needed)
      SELECT r.po, r.eq, tstzrange(r.lo, r.hi), true
       WHERE NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime x
                          WHERE x.id_equipment = r.eq
                            AND x.runtime_timerange && tstzrange(r.lo, r.hi));
      IF FOUND THEN n := n + 1; END IF;
    EXCEPTION WHEN exclusion_violation THEN
      NULL; -- overlapping window, skip
    END;
  END LOOP;
  RAISE NOTICE 't-cpack-backfill-po-runtime-windows: created % runtime windows', n;
END $$;
