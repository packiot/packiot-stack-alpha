-- mock-bispharma-box-scans.sql — one TICK of the Bispharma (ent-5) live box-scan mock.
-- Run periodically by the bispharma-box-scan-mock compose service. STAGING ONLY.
--
-- WHY: Bispharma is a box-scan-HEAVY client (its key feature). The synthetic seed
-- (seed_bispharma_boxes.sql) produced a STATIC one-shot dataset; this makes box scans
-- ARRIVE CONTINUOUSLY — a faithful mock of a scanner on a running line — so the Superset
-- "Scanned Boxes" dashboard shows live-growing counts (as the real feed will). Writes the
-- same shape the barcode-service does: gapless label_seq per PO, server-decided
-- counts_toward_total, gold.po_box_counter kept in lockstep. Real scans overwrite when the
-- box comes online. Reversible: everything keyed to id_production_order = 9995010.
--
-- Anchored to L01 (2000224, SP site) — the line the twin also feeds live telemetry for —
-- so box scans and OEE tell one coherent story for the same line.

BEGIN;

-- 1. Ensure ONE running (status=2) demo PO exists to scan against (idempotent).
INSERT INTO core.production_orders
  (id_production_order, id_enterprise, id_site, id_area, id_equipment, status, id_order,
   nm_production_order, ts_start, recalc_needed, oee_processed)
VALUES
  (9995010, 5, 2000009, 2000020, 2000224, 2, 9995010,
   'BISPHARMA-LIVE-BOXSCAN-L01', now(), false, false)
ON CONFLICT (id_production_order) DO NOTHING;

-- 2. Append a small batch of FRESH scans, label_seq continuing gaplessly from the current
--    max for this PO. ~1 in 17 is a void (qty 0, does not count toward total).
WITH cur AS (
  SELECT COALESCE(max(label_seq), 0) AS last_seq
    FROM bronze.box_scans WHERE id_production_order = 9995010
),
batch AS (
  SELECT c.last_seq + g AS label_seq,
         CASE WHEN (c.last_seq + g) % 17 = 0 THEN 'void' ELSE 'production' END AS scan_type,
         CASE WHEN (c.last_seq + g) % 17 = 0 THEN 0 ELSE 20 + ((c.last_seq + g) % 5) END AS qty,
         now() - ((5 - g) * interval '3 seconds') AS ts_v  -- spread across the tick
    FROM cur c, generate_series(1, 5) AS g
)
INSERT INTO bronze.box_scans
  (id_enterprise, id_site, id_area, id_equipment, id_production_order, id_order,
   scan_type, label_seq, qty, counts_toward_total, raw_barcode, scan_uuid, ts_value)
SELECT 5, 2000009, 2000020, 2000224, 9995010, 9995010,
       scan_type, label_seq, qty, (scan_type = 'production'),
       '9995010;' || label_seq || ';' || qty, gen_random_uuid(), ts_v
FROM batch;

-- 3. Keep the PO box counter in lockstep (last_label_seq + counted total).
INSERT INTO gold.po_box_counter (id_production_order, id_enterprise, last_label_seq, total_qty, updated_at)
SELECT 9995010, 5, max(label_seq), sum(qty) FILTER (WHERE counts_toward_total), now()
  FROM bronze.box_scans WHERE id_production_order = 9995010
ON CONFLICT (id_production_order) DO UPDATE
  SET last_label_seq = EXCLUDED.last_label_seq,
      total_qty      = EXCLUDED.total_qty,
      updated_at     = EXCLUDED.updated_at;

COMMIT;
