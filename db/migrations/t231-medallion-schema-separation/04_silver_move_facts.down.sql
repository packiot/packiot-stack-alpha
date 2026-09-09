-- t231 · PHASE 4 (SILVER) — reversal. Symmetric to the up: drop the public shim
-- view, then move the fact back to public. Chunks/policies/caggs/bi views follow
-- by OID. Per-table own tx with lock_timeout + retry (same discipline as the up).
--
-- ROLLBACK ORDERING: run this AFTER redeploying the PRIOR stream-engine image
-- (facts → public) and re-pointing the historian FDW back to public, so the
-- ingest writer and FDW target `public.equipment_values` again. The brief window
-- is absorbed by the RabbitMQ-durable NACK/retry, same as the forward cutover.

-- equipment_live_metrics
DO $$
DECLARE i int; done boolean := false;
BEGIN
  FOR i IN 1..15 LOOP
    BEGIN
      SET LOCAL lock_timeout = '30s';
      DROP VIEW IF EXISTS public.equipment_live_metrics;
      ALTER TABLE silver.equipment_live_metrics SET SCHEMA public;
      done := true; EXIT;
    EXCEPTION WHEN lock_not_available THEN PERFORM pg_sleep(1);
    END;
  END LOOP;
  IF NOT done THEN RAISE EXCEPTION 't231 P4 down: equipment_live_metrics'; END IF;
END $$;

-- equipment_events
DO $$
DECLARE i int; done boolean := false;
BEGIN
  FOR i IN 1..15 LOOP
    BEGIN
      SET LOCAL lock_timeout = '30s';
      DROP VIEW IF EXISTS public.equipment_events;
      ALTER TABLE silver.equipment_events SET SCHEMA public;
      done := true; EXIT;
    EXCEPTION WHEN lock_not_available THEN PERFORM pg_sleep(1);
    END;
  END LOOP;
  IF NOT done THEN RAISE EXCEPTION 't231 P4 down: equipment_events'; END IF;
END $$;

-- equipment_values
DO $$
DECLARE i int; done boolean := false;
BEGIN
  FOR i IN 1..15 LOOP
    BEGIN
      SET LOCAL lock_timeout = '30s';
      DROP VIEW IF EXISTS public.equipment_values;
      ALTER TABLE silver.equipment_values SET SCHEMA public;
      done := true; EXIT;
    EXCEPTION WHEN lock_not_available THEN PERFORM pg_sleep(1);
    END;
  END LOOP;
  IF NOT done THEN RAISE EXCEPTION 't231 P4 down: equipment_values'; END IF;
END $$;
