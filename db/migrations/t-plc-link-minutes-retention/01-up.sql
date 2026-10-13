-- t-plc-link-minutes-retention — give silver.plc_link_minutes a lifetime (2026-10-13)
--
-- WHY: t-plc-link-health (2026-10-01) created the hypertable with no retention
-- policy and no ops.retention_policy row, so it grows forever (one row per
-- tenant × PLC endpoint × minute) and ops.retention_drift cannot see it: the
-- drift view only compares catalog rows with live policies, and this relation
-- had neither.
--
-- KEEP = 90 days, tier hot_raw — the same as every other minute-grain silver
-- relation (silver.equipment_values, *_1min caggs) and the bronze replay window:
--   * every reader looks back far less: the link-aware stop deriver
--     (stream-engine internal/events/cpac_deriver.go) reads the last 27 h plus
--     min(ts_minute) per endpoint ("has this endpoint ever reported"); the data
--     invariants read 7 d / 1 h / 15 min;
--   * what the minutes are used FOR is already persisted elsewhere: the NO DATA
--     spans become status-20 rows in silver.equipment_events (5 years);
--   * min(ts_minute) still answers "reported before" for any endpoint that
--     reported in the last 90 days; the deriver only considers equipment that
--     produced in the last 7 days, so an endpoint silent for 90+ days is out of
--     its scope either way.
-- Nothing is deleted today: the table holds data since 2026-10-01, so the
-- first chunk the policy can drop ages out around 2026-12-30.
--
-- Scope: this inserts the catalog row and reconciles the Timescale policy for
-- THIS relation only (same logic as ops.apply_retention()), so applying it can
-- never change another relation's live policy. Idempotent. Not applied by any
-- deploy: an operator applies it (docs/wiki/build/develop/add-a-migration.md).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

INSERT INTO ops.retention_policy (relation, kind, time_expr, keep, tier, purge_order, cold_copy, rationale) VALUES
 ('silver.plc_link_minutes', 'hypertable', 'ts_minute', '90 days', 'hot_raw', 100, NULL,
  'PLC link health per endpoint × minute (sparkplug-agent linkhealth). Readers look back ≤ 27 h (stop deriver) / 7 d (invariants); NO DATA spans are persisted in silver.equipment_events.')
ON CONFLICT (relation) DO NOTHING;

-- Reconcile the live policy to the catalog row (which may already exist with an
-- operator-chosen keep — the catalog wins, as in ops.apply_retention()).
DO $$
DECLARE want interval; live interval;
BEGIN
  EXECUTE 'SELECT ts_minute FROM silver.plc_link_minutes LIMIT 0';  -- time_expr is valid
  SELECT keep INTO want FROM ops.retention_policy WHERE relation = 'silver.plc_link_minutes';
  SELECT (config->>'drop_after')::interval INTO live
    FROM timescaledb_information.jobs
   WHERE proc_name = 'policy_retention'
     AND hypertable_schema = 'silver' AND hypertable_name = 'plc_link_minutes';
  IF want IS DISTINCT FROM live THEN
    PERFORM remove_retention_policy('silver.plc_link_minutes'::regclass, if_exists => true);
    IF want IS NOT NULL THEN
      PERFORM add_retention_policy('silver.plc_link_minutes'::regclass, drop_after => want);
    END IF;
    RAISE NOTICE 'retention silver.plc_link_minutes : % -> %', coalesce(live::text, 'forever'), coalesce(want::text, 'forever');
  END IF;
END $$;

COMMIT;
