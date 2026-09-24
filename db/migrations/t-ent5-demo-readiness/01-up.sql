-- t-ent5-demo-readiness — make Bispharma (ent 5) presentable to the client (2026-09-24).
-- STAGING-ONLY (BDR values are computed from staging data). Applied manually 2026-09-24.
-- Re-running is safe (idempotent updates; guards pass on an empty order set).
--
-- (1) RATED SPEED = BEST DEMONSTRATED RATE (BDR), replacing the MOCK speeds.
--     t-bispharma-mock-rated-speeds gave every ent5 machine a HASHED placeholder (65–135/min)
--     for the old synthetic twin. The feed is now the REAL box, and the mocks were wrong in
--     both directions (L56 mock 128 vs runs ~80; L16 mock 87 vs runs ~110 → Performance
--     pinned ~1.0 and fake "world-class" 0.9 OEE). Until Bispharma sends nameplate speeds we
--     use the TPM-standard interim: BDR = p90 of the machine's own 15-MINUTE throughput over
--     the last 14 days (producing windows only). 15-min windows, not 1-min: the box→cloud
--     feed is lossy and a post after a gap carries the accumulated count in ONE minute
--     (1-min spikes up to 13,237/min; L01 1-min p95 = 604) — the window absorbs the catch-up.
--     Only machines with >= 100 producing windows; EXCLUDED: L03/S4 (rate ≈ 0, trickle) and
--     L60's M682/M683 (flat p50≈p90 = stuck counter before the PLC died). The other 52 machines have
--     too little data and keep their current value. Performance now reads "vs your best
--     demonstrated rate"; replace with nameplates (CS, csadmin) when the client provides them.
--     Computed 2026-09-24 ~16:20 UTC:
--       silver.equipment_metrics_1min, time_bucket('15 min'), rate = sum(max(gross,net))/15,
--       percentile_cont(0.9) over rate > 0.
--
-- (2) TARGET UNITS BUG (from #1381, mine): config.piot_line_default_target_hour returned
--     round(production_speed × 0.85) — but production_speed is units per MINUTE (gold
--     ideal_production = ideal_speed × 60), so vl_hour was 60× too small (L01: target 59/h
--     while producing ~3,800/h). Only ent5 received non-zero seeded targets. Fixed (×60) and
--     ent5 targets recomputed from the BDR lead speeds.
--
-- (3) CLEAN SLATE for orders: all 24 ent5 production orders are internal test artifacts
--     (DEMO-*, DEPLOY-VERIFY, GAP7-*, BISPHARMA-*; 0 products / 0 clients in the tenant).
--     Deleted with their runtimes / box rows. Guarded: aborts if any ent5 order does NOT
--     match the test-name patterns. The demo starts a real order live in operator.
--
-- (4) Recompute: see step (4) below (bounded — the first, unbounded version stalled the rollup).
--
-- BACKUP: ops._bkp_ent5_demo_20260924 (speeds, targets, orders, runtimes as jsonb).
-- ROLLBACK: rollback.sql restores speeds + targets + orders from the backup.

BEGIN;

CREATE TABLE IF NOT EXISTS ops._bkp_ent5_demo_20260924 (kind text, row jsonb, backed_up_at timestamptz DEFAULT now());
INSERT INTO ops._bkp_ent5_demo_20260924 (kind, row)
  SELECT 'equipment_speed', jsonb_build_object('id_equipment', id_equipment, 'production_speed', production_speed)
    FROM core.equipments WHERE id_enterprise = 5
  UNION ALL SELECT 'production_target', to_jsonb(t) FROM config.production_targets t WHERE id_enterprise = 5
  UNION ALL SELECT 'production_order', to_jsonb(p) FROM core.production_orders p WHERE id_enterprise = 5
  UNION ALL SELECT 'po_runtime', to_jsonb(r) FROM gold.production_orders_runtime r
             JOIN core.production_orders p USING (id_production_order) WHERE p.id_enterprise = 5;

-- (1) BDR speeds (id_equipment, units/min)
UPDATE core.equipments e SET production_speed = v.bdr
  FROM (VALUES
    (2000225, 79),  -- L01/S1INFEED  mock 84  p50 53  p90 79  (892 windows)
    (2000226, 81),  -- L01/S3  mock 111  p50 57  p90 81  (940 windows)
    (2000232, 68),  -- L03/S1INFEED  mock 69  p50 61  p90 68  (896 windows)
    (2000233, 73),  -- L03/S3  mock 124  p50 68  p90 73  (899 windows)
    (2000235, 72),  -- L03/S5  mock 84  p50 66  p90 72  (918 windows)
    (2000239, 63),  -- L04/S1INFEED  mock 86  p50 56  p90 63  (913 windows)
    (2000240, 70),  -- L04/S3  mock 91  p50 58  p90 70  (936 windows)
    (2000246, 67),  -- L05/S1INFEED  mock 88  p50 57  p90 67  (912 windows)
    (2000247, 69),  -- L05/S3  mock 87  p50 63  p90 69  (930 windows)
    (2000248, 68),  -- L05/S4  mock 116  p50 62  p90 68  (932 windows)
    (2000249, 67),  -- L05/S5  mock 130  p50 61  p90 67  (941 windows)
    (2000253, 91),  -- L06/S1INFEED  mock 125  p50 79  p90 91  (895 windows)
    (2000254, 91),  -- L06/S3  mock 72  p50 84  p90 91  (906 windows)
    (2000255, 91),  -- L06/S4  mock 70  p50 85  p90 91  (913 windows)
    (2000256, 91),  -- L06/S5  mock 102  p50 81  p90 91  (895 windows)
    (2000260, 94),  -- L07/S1INFEED  mock 81  p50 85  p90 94  (960 windows)
    (2000261, 101),  -- L07/S3  mock 97  p50 91  p90 101  (966 windows)
    (2000267, 73),  -- L09/S1INFEED  mock 99  p50 65  p90 73  (856 windows)
    (2000268, 77),  -- L09/S3  mock 129  p50 69  p90 77  (894 windows)
    (2000274, 80),  -- L11/S1INFEED  mock 98  p50 68  p90 80  (877 windows)
    (2000275, 88),  -- L11/S3  mock 87  p50 71  p90 88  (879 windows)
    (2000281, 77),  -- L12/S1INFEED  mock 114  p50 65  p90 77  (923 windows)
    (2000282, 83),  -- L12/S3  mock 67  p50 74  p90 83  (912 windows)
    (2000284, 83),  -- L12/S5  mock 100  p50 63  p90 83  (794 windows)
    (2000288, 86),  -- L13/S1INFEED  mock 111  p50 71  p90 86  (896 windows)
    (2000289, 91),  -- L13/S3  mock 85  p50 82  p90 91  (937 windows)
    (2000295, 84),  -- L14/S1INFEED  mock 106  p50 74  p90 84  (941 windows)
    (2000296, 87),  -- L14/S3  mock 129  p50 80  p90 87  (961 windows)
    (2000302, 110),  -- L16/S1INFEED  mock 87  p50 100  p90 110  (935 windows)
    (2000303, 118),  -- L16/S3  mock 117  p50 109  p90 118  (947 windows)
    (2000305, 114),  -- L16/S5  mock 115  p50 105  p90 114  (937 windows)
    (2000309, 141),  -- L18/ACUMULADOR  mock 101  p50 129  p90 141  (898 windows)
    (2000311, 140),  -- L18/PRENSA  mock 77  p50 129  p90 140  (898 windows)
    (2000312, 134),  -- L18/TAMPADEIRA  mock 115  p50 121  p90 134  (899 windows)
    (2000315, 69),  -- L19/S1INFEED  mock 69  p50 57  p90 69  (904 windows)
    (2000316, 71),  -- L19/S3  mock 82  p50 63  p90 71  (921 windows)
    (2000322, 70),  -- L20/S1INFEED  mock 66  p50 61  p90 70  (905 windows)
    (2000323, 72),  -- L20/S3  mock 111  p50 67  p90 72  (933 windows)
    (2000325, 71),  -- L20/S5  mock 78  p50 65  p90 71  (924 windows)
    (2000341, 79),  -- L56/M676  mock 128  p50 60  p90 79  (565 windows)
    (2000342, 71),  -- L56/M677  mock 110  p50 49  p90 71  (514 windows)
    (2000344, 73),  -- L57/M678  mock 126  p50 62  p90 73  (822 windows)
    (2000345, 72),  -- L57/M679  mock 73  p50 57  p90 72  (844 windows)
    (2000347, 69),  -- L58/M680  mock 67  p50 55  p90 69  (304 windows)
    (2000348, 79),  -- L58/M681  mock 100  p50 69  p90 79  (287 windows)
    (2000332, 90),  -- L71/M670  mock 107  p50 81  p90 90  (745 windows)
    (2000333, 84),  -- L71/M671  mock 95  p50 57  p90 84  (737 windows)
    (2000335, 75),  -- L72/M672  mock 84  p50 59  p90 75  (760 windows)
    (2000336, 70),  -- L72/M673  mock 97  p50 44  p90 70  (734 windows)
    (2000338, 91),  -- L73/M674  mock 126  p50 88  p90 91  (795 windows)
    (2000339, 99),  -- L73/M675  mock 114  p50 80  p90 99  (897 windows)
    (2000329, 65),  -- L90/S1INFEED  mock 97  p50 59  p90 65  (389 windows)
    (2000330, 60)   -- L90/S2OUTPUT  mock 78  p50 48  p90 60  (440 windows)
  ) v(id_equipment, bdr)
 WHERE e.id_equipment = v.id_equipment AND e.id_enterprise = 5;

-- (2) target-hour units fix + recompute ent5 targets
CREATE OR REPLACE FUNCTION config.piot_line_default_target_hour(p_line integer) RETURNS integer
  LANGUAGE sql STABLE AS $fn$
  -- units/min × 60 = units/hour, at the world-class 85% OEE (A90×P95×Q99.9, TPM).
  SELECT round(COALESCE(m.production_speed, 0) * 60 * 0.85)::int
    FROM core.equipments l
    LEFT JOIN core.equipments m ON m.id_equipment = l.lead_machine
   WHERE l.id_equipment = p_line;
$fn$;

UPDATE config.production_targets t
   SET vl_hour = h, vl_shift = h * 8, vl_day = h * 24, vl_week = h * 24 * 7, vl_month = h * 24 * 30
  FROM (SELECT id_equipment, config.piot_line_default_target_hour(id_equipment) h
          FROM core.equipments WHERE id_enterprise = 5 AND tp_equipment = 3) x
 WHERE t.id_equipment = x.id_equipment AND x.h > 0;

-- (3) clean slate: test orders only (guarded)
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM core.production_orders
   WHERE id_enterprise = 5
     AND nm_production_order !~ '^(DEMO-|DEPLOY-VERIFY|GAP7-|BISPHARMA-)';
  IF bad > 0 THEN
    RAISE EXCEPTION 'ent5 has % non-test production orders — refusing to delete (real data?)', bad;
  END IF;
END $$;
-- SYNTHETIC box scans (132,055 from the bispharma-box-scan-mock on PO 9995010 + 295 from
-- seed_bispharma_boxes.sql on 9995001–9995006; ZERO real scans — the real scanner is not
-- online). bronze.box_scans is APPEND-ONLY by design (box_scans_no_mutate) to protect REAL
-- scan history; these rows are generated, and the mock declares itself reversible "keyed to
-- id_production_order". Guard: abort if any ent5 scan belongs to a non-synthetic order.
-- Triggers are bypassed ONLY around this one DELETE: session_replication_role=replica also
-- disables FK enforcement (FKs are triggers), so it is reset before the order deletes.
-- The mock itself was disabled (BISPHARMA_BOX_SCAN_MOCK_ENABLED=false) before this ran.
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM bronze.box_scans b
    LEFT JOIN core.production_orders p ON p.id_production_order = b.id_production_order
   WHERE b.id_enterprise = 5 AND coalesce(p.nm_production_order, '') !~ '^BISPHARMA-';
  IF bad > 0 THEN
    RAISE EXCEPTION 'ent5 has % box scans on non-synthetic orders — refusing to purge', bad;
  END IF;
END $$;
SET LOCAL session_replication_role = replica;
DELETE FROM bronze.box_scans WHERE id_enterprise = 5;
SET LOCAL session_replication_role = origin;
DELETE FROM gold.po_box_counter WHERE id_production_order IN (SELECT id_production_order FROM core.production_orders WHERE id_enterprise = 5);
DELETE FROM gold.production_orders_runtime WHERE id_production_order IN (SELECT id_production_order FROM core.production_orders WHERE id_enterprise = 5);
DELETE FROM core.production_orders WHERE id_enterprise = 5;

-- (4) recompute with the new speeds — ONLY the last 2 days of LINE shifts + 24 h of line hours.
-- LESSON (2026-09-24, applied live): the first version flagged 14 d of line shifts, 3 d of
-- MACHINE shifts and 7 d of line hours. (a) A 75-row batch of counters-only line shifts blew
-- the shift job deadline ("events-bank: timeout") → the WHOLE shift tx rolled back every tick
-- → current-shift OEE stalled for EVERY tenant. (b) Machine (tp=1) shift rows are only
-- computed for ROLLUP_MACHINE_LEVEL_ENTERPRISES (=6) → ent5 tp=1 flags are PHANTOM (never
-- cleared). (c) 200-row hour-backfill batches of line hours timed out every tick. Older
-- history is recomputed one day per tick by scripts/ops/refill-shift-history.sh.
UPDATE gold.equipment_oee_shift o SET recalc_needed = true FROM core.equipments e
 WHERE o.id_equipment = e.id_equipment AND e.id_enterprise = 5 AND e.tp_equipment = 3
   AND o.ts_value > now() - interval '2 days' AND o.ts_value <= now();
UPDATE gold.equipment_oee_hourly o SET recalc_needed = true FROM core.equipments e
 WHERE o.id_equipment = e.id_equipment AND e.id_enterprise = 5 AND e.tp_equipment = 3
   AND o.ts_value > now() - interval '24 hours' AND o.ts_value <= now();

COMMIT;
