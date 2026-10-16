-- t-line-meter-fill — per-line switch for the line-lead identity fill
--
-- The line-lead reconcile (stream-engine line_lead.go shift + hour, compute.go PO)
-- treats a gross/net meter that is silent for a whole hour as MISSING and fills it
-- from the other one (gross := net, net := gross). Right for a meter that loses
-- units (CPACK L3/L4 outfeeds: Sept raw net 2.68M/2.93M vs gross 3.26M/3.82M).
-- Wrong for a report-by-exception TOTALIZER: a silent hour's units arrive in the
-- next report's delta, so the fill counts them twice. Bispharma L90 (split meter:
-- S1INFEED gross, S2OUTPUT net), 09-01..09-30: infeed 677,324, outfeed 639,683,
-- filled gross 757,891 (+12%), net 672,810 (+5%).
--
-- fill_missing_meter: NULL/true = fill (default, unchanged); false = take each
-- meter as measured, 0 when silent. Additive + idempotent.
-- Apply BEFORE the stream-engine that reads the column.
BEGIN;

ALTER TABLE core.equipments ADD COLUMN IF NOT EXISTS fill_missing_meter boolean;

COMMENT ON COLUMN core.equipments.fill_missing_meter IS
  'LINE only: false = the line''s gross/net meters are report-by-exception totalizers (a silent hour is a real zero; its units arrive in the next delta), so the line-lead reconcile takes them as measured instead of filling a silent meter from the other. NULL/true = fill (default).';

UPDATE core.equipments
   SET fill_missing_meter = false
 WHERE id_enterprise = 5 AND tp_equipment = 3 AND nm_equipment = 'L90'
   AND fill_missing_meter IS DISTINCT FROM false;

COMMIT;
