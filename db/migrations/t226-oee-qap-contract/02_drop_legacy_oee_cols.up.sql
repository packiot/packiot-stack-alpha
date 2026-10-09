-- #226 item 1 (oee_q CONTRACT — drop phase). Companion to 01 (reader repoint)
-- and the stream-engine writer flip (recalc.go now SETs oee_q/oee_a/oee_p).
--
-- PRECONDITIONS (all proven live before applying):
--   * WRITER: stream-engine recalc.go writes oee_q/oee_a/oee_p (deployed). It is
--     the SOLE writer of the OEE factor columns on production_orders (writer-audit:
--     analytics-sync / mirror-worker-go / edge-api INSERT+UPDATE PO lifecycle only,
--     never the oee_* factors; createpo.go INSERT omits them).
--   * READERS: the only two — bi.production_orders (Superset serving view, repointed
--     in 01) and read-api refdata-api datasets.go (po.oee_a AS oee_availability, …) —
--     read the canonical oee_q/oee_a/oee_p. No DB function/view references the legacy
--     names (verified: pg_proc prokind='f' + pg_views scans return 0).
--   * The old->new dual-write trigger is now INERT: it fires only on
--     `UPDATE OF oee_quality, oee_availability, oee_performance`, which no writer
--     issues anymore, so it never runs.
--
-- Dropping the trigger + its function + the three legacy columns. CASCADE is NOT
-- used: the columns have no remaining dependents (the bi view no longer selects
-- them). If a hidden dependency existed the DROP would error rather than silently
-- cascade — that is the intended guardrail.

BEGIN;

-- 1. Trigger first (it is defined ON the columns about to be dropped).
DROP TRIGGER IF EXISTS trg_po_oee_qap_dualwrite ON public.production_orders;
DROP FUNCTION IF EXISTS public.po_oee_qap_dualwrite();

-- 2. The three legacy factor columns (oee, the composite, keeps its canonical name).
ALTER TABLE public.production_orders
  DROP COLUMN IF EXISTS oee_quality,
  DROP COLUMN IF EXISTS oee_availability,
  DROP COLUMN IF EXISTS oee_performance;

COMMIT;
