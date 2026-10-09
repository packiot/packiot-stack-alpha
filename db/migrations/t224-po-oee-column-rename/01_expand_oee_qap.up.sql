-- #224 P4 column rename (EXPAND phase) production_orders
--   oee_quality/oee_availability/oee_performance -> oee_q/oee_a/oee_p
-- Expand/contract (NOT a plain rename): a LIVE external writer sets the old cols and
-- Superset bi.production_orders reads them. This phase is additive + reversible: add
-- the new cols, backfill, and dual-write old->new via a BEFORE trigger so the new cols
-- stay coherent while the external writer still targets the old names. Repoint (writer
-- + bi.* to new) and contract (drop old cols + trigger) land in later phases.

ALTER TABLE public.production_orders
  ADD COLUMN IF NOT EXISTS oee_q double precision,
  ADD COLUMN IF NOT EXISTS oee_a double precision,
  ADD COLUMN IF NOT EXISTS oee_p double precision;

-- Backfill existing rows.
UPDATE public.production_orders
   SET oee_q = oee_quality, oee_a = oee_availability, oee_p = oee_performance
 WHERE oee_q IS DISTINCT FROM oee_quality
    OR oee_a IS DISTINCT FROM oee_availability
    OR oee_p IS DISTINCT FROM oee_performance;

-- Dual-write old->new (writers still set the old cols today; keeps new cols coherent).
CREATE OR REPLACE FUNCTION public.po_oee_qap_dualwrite() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.oee_q := NEW.oee_quality;
  NEW.oee_a := NEW.oee_availability;
  NEW.oee_p := NEW.oee_performance;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_po_oee_qap_dualwrite ON public.production_orders;
CREATE TRIGGER trg_po_oee_qap_dualwrite
  BEFORE INSERT OR UPDATE OF oee_quality, oee_availability, oee_performance
  ON public.production_orders
  FOR EACH ROW EXECUTE FUNCTION public.po_oee_qap_dualwrite();
