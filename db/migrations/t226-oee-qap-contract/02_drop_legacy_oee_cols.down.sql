-- Revert 02: re-add the legacy OEE factor columns, backfill them from the
-- canonical oee_q/oee_a/oee_p, and restore the old->new dual-write trigger so the
-- pre-contract invariant (oee_quality == oee_q for every row) holds again. Pair
-- this with reverting the stream-engine writer flip (recalc.go back to the legacy
-- column names) — this migration alone restores the schema; the writer revert
-- restores who keeps them fresh.

BEGIN;

ALTER TABLE public.production_orders
  ADD COLUMN IF NOT EXISTS oee_quality      double precision,
  ADD COLUMN IF NOT EXISTS oee_availability double precision,
  ADD COLUMN IF NOT EXISTS oee_performance  double precision;

-- Backfill from the canonical columns (they are authoritative post-contract).
UPDATE public.production_orders
   SET oee_quality      = oee_q,
       oee_availability = oee_a,
       oee_performance  = oee_p;

-- Restore the dual-write trigger (legacy old->new mirror), gated on the old cols.
CREATE OR REPLACE FUNCTION public.po_oee_qap_dualwrite()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.oee_q := NEW.oee_quality;
  NEW.oee_a := NEW.oee_availability;
  NEW.oee_p := NEW.oee_performance;
  RETURN NEW;
END $function$;

CREATE TRIGGER trg_po_oee_qap_dualwrite
  BEFORE INSERT OR UPDATE OF oee_quality, oee_availability, oee_performance
  ON public.production_orders
  FOR EACH ROW EXECUTE FUNCTION public.po_oee_qap_dualwrite();

COMMIT;
