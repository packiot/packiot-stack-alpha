-- t231 · Medallion schema separation — PHASE 4 (SILVER, live-ingest cutover)
-- DB: packiot_analytics (STAGING). DO NOT run on prod (packiot40 forward-port).
--
-- Moves the merged/current-state FACT relations into `silver` and leaves an
-- auto-updatable public shim VIEW at each old name (expand/contract):
--   * equipment_values        (hypertable — live UPSERT ingest fact)
--   * equipment_events         (hypertable — stream-engine mint + analytics-sync)
--   * equipment_live_metrics   (plain table — uns current-state UPSERT)
--
-- ORDERING CONTRACT — deploy the refactored stream-engine FIRST (facts →
-- Dest.SilverSchema), THEN run this. The refactored ingest writes
-- silver.equipment_values/events directly; until this migration creates them
-- those writes 42P01 → handler returns error → consumer NACK → DLX(oee-retry,
-- 30s TTL, 5 retries) → redeliver. The ingest is RabbitMQ-DURABLE, so the brief
-- failed-write window (deploy-healthy → this migration) reprocesses with NO data
-- loss. Keep the window well under the ~150s retry budget.
--
-- WRITERS through the public shim (hardproofed on staging, 2026-09-09, throwaway
-- hypertable+view): analytics-sync writes public.equipment_events via
-- `INSERT ... ON CONFLICT (id_equipment, ts_event) DO NOTHING` + `UPDATE ... WHERE`.
-- Both traverse an auto-updatable view into a silver hypertable correctly
-- (INSERT 0 1 fresh / INSERT 0 0 on-conflict-no-op / UPDATE 1). analytics-sync's
-- hardcoded `public.` is repointed to `silver.` in t231 PHASE 5 (writer-audit
-- #186: the shim is the compat surface until every writer is off the old name).
-- READERS through the shim: the rollup (flows.Dest.EvSchema="public" →
-- `public.equipment_values`), bake.go, terraform VACUUM/drop_chunks.
--
-- OID-FOLLOW (no action, proven §2/§3 of the design + re-verified post-move):
-- the silver caggs (equipment_metrics_*/categorical_*), the legacy public
-- agg_*/ca_* caggs, compression+retention policies, and every bi.*/serving view
-- reference the base by internal id — they follow SET SCHEMA automatically.
--
-- LOCK DISCIPLINE: SET SCHEMA needs ACCESS EXCLUSIVE. The live ingest writer
-- does NOT hold a lock on public.equipment_values during the window (its writes
-- 42P01 before taking any lock); the contending holders are READERS (rollup
-- ACCESS SHARE, historian FDW, Superset). Each table moves in its OWN
-- transaction with lock_timeout + a bounded retry loop so the ALTER queues and
-- grabs ACCESS EXCLUSIVE the instant a reader txn commits (sub-second hold). The
-- ALTER + shim CREATE VIEW share the table's transaction, so there is never a
-- window where the public name is absent for the shim's readers/writers.

CREATE SCHEMA IF NOT EXISTS silver;

-- equipment_values (hypertable, live ingest fact)
DO $$
DECLARE i int; done boolean := false;
BEGIN
  FOR i IN 1..15 LOOP
    BEGIN
      SET LOCAL lock_timeout = '30s';
      ALTER TABLE public.equipment_values SET SCHEMA silver;
      CREATE VIEW public.equipment_values AS SELECT * FROM silver.equipment_values;
      done := true;
      RAISE NOTICE 't231 P4: equipment_values -> silver (+shim) on attempt %', i;
      EXIT;
    EXCEPTION WHEN lock_not_available THEN
      RAISE NOTICE 't231 P4: equipment_values lock_timeout, retry % ...', i;
      PERFORM pg_sleep(1);
    END;
  END LOOP;
  IF NOT done THEN RAISE EXCEPTION 't231 P4: could not move equipment_values after retries'; END IF;
END $$;

-- equipment_events (hypertable; stream-engine mint + analytics-sync shim writes)
DO $$
DECLARE i int; done boolean := false;
BEGIN
  FOR i IN 1..15 LOOP
    BEGIN
      SET LOCAL lock_timeout = '30s';
      ALTER TABLE public.equipment_events SET SCHEMA silver;
      CREATE VIEW public.equipment_events AS SELECT * FROM silver.equipment_events;
      done := true;
      RAISE NOTICE 't231 P4: equipment_events -> silver (+shim) on attempt %', i;
      EXIT;
    EXCEPTION WHEN lock_not_available THEN
      RAISE NOTICE 't231 P4: equipment_events lock_timeout, retry % ...', i;
      PERFORM pg_sleep(1);
    END;
  END LOOP;
  IF NOT done THEN RAISE EXCEPTION 't231 P4: could not move equipment_events after retries'; END IF;
END $$;

-- equipment_live_metrics (plain table; uns current-state UPSERT)
DO $$
DECLARE i int; done boolean := false;
BEGIN
  FOR i IN 1..15 LOOP
    BEGIN
      SET LOCAL lock_timeout = '30s';
      ALTER TABLE public.equipment_live_metrics SET SCHEMA silver;
      CREATE VIEW public.equipment_live_metrics AS SELECT * FROM silver.equipment_live_metrics;
      done := true;
      RAISE NOTICE 't231 P4: equipment_live_metrics -> silver (+shim) on attempt %', i;
      EXIT;
    EXCEPTION WHEN lock_not_available THEN
      RAISE NOTICE 't231 P4: equipment_live_metrics lock_timeout, retry % ...', i;
      PERFORM pg_sleep(1);
    END;
  END LOOP;
  IF NOT done THEN RAISE EXCEPTION 't231 P4: could not move equipment_live_metrics after retries'; END IF;
END $$;

-- CONTRACT (drop the public shims + repoint analytics-sync/bake/terraform off
-- `public.` fact names) is DEFERRED to t231 PHASE 5, after the readers/writers
-- are confirmed off the public names (writer-audit #186).
