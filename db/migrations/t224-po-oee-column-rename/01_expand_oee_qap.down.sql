-- Reversal of the EXPAND phase (fully reversible; old cols never touched).
DROP TRIGGER IF EXISTS trg_po_oee_qap_dualwrite ON public.production_orders;
DROP FUNCTION IF EXISTS public.po_oee_qap_dualwrite();
ALTER TABLE public.production_orders
  DROP COLUMN IF EXISTS oee_q,
  DROP COLUMN IF EXISTS oee_a,
  DROP COLUMN IF EXISTS oee_p;
