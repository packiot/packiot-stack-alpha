-- #206 — cagg provisioning recurrence-preventer (idempotent).
--
-- WHY: the #196 incident (CPACK OEE stale, rollup ticks timing out at 300s) was
-- caused by the two rollup-critical real-time continuous aggregates
--   ca_agg_equipment_values_1min   (stream-engine hour/shift VALUE + line-lead pass)
--   ca_agg_equipment_values_1hour  (stream-engine hour/shift VALUE + line-lead pass)
-- having NO refresh policy. A real-time cagg (materialized_only=false) with no
-- refresh policy has a FROZEN materialization watermark, so every read
-- re-aggregates ALL raw equipment_values past the watermark — query cost grows
-- with ingest until a tick crosses its statement timeout. Root cause of recurrence:
-- db/init-f3/snapshot/10-f3-timescale-supplement.sql CREATEd these caggs but never
-- paired the CREATE with add_continuous_aggregate_policy. The snapshot is now fixed
-- (fresh DBs are correct by construction); this migration closes the gap on any
-- ALREADY-EXISTING database and stands as an idempotent, assertable guard.
--
-- SAFETY (read this before running on a NEW database):
--   Attaching a refresh policy to a real-time cagg whose watermark is FROZEN
--   mid-history and that already holds data will jump the watermark forward on the
--   policy's first run and turn the un-refreshed older span into a READ-HOLE
--   (the #196 "MID-FIX TRAP"). This migration is SAFE on prod + staging because
--   both already carry the ca_agg_* refresh policies (jobs exist) → the attach
--   below is a pure no-op (if_not_exists). If you ever run this against a DB where
--   a rollup-critical cagg is policy-less AND holds data, you MUST first catch it
--   up oldest-first across the whole gap:
--     CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_1min',  <gap_start>, now());
--     CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_1hour', <gap_start>, now());
--   (refresh_continuous_aggregate cannot run inside a transaction/DO block, so it
--   is intentionally NOT part of this migration.)
--
-- SCOPE: only the two ROLLUP-CRITICAL ca_agg_* caggs are attached + asserted here.
--   The other real-time ca_* caggs (ca_discrete_changes_1s, ca_equipment_boxes_1s,
--   ca_equipment_boxes_1hour) were assessed (#208): their watermark is -infinity
--   (NOT frozen mid-history), so materialized_only=false serves their reads fully
--   with no holes and their consumers are bounded/absent on prod — they are SAFE
--   left as-is, and blindly attaching a policy would (per the trap above) need an
--   oldest-first catch-up first. They are surfaced as a NOTICE, never auto-attached.
--
-- Offsets mirror the prod-proven hotfix jobs (1010: 2h/1m/1m ; 1011: 3d/1h/30m).
-- IDEMPOTENCY: the attach is guarded by an explicit "no refresh job exists yet"
-- check. This is deliberate — add_continuous_aggregate_policy(if_not_exists=>true)
-- is a no-op ONLY when a policy with the EXACT same offsets already exists; when a
-- policy with DIFFERENT offsets exists it RAISES "refresh interval overlaps ..."
-- (observed on staging, TimescaleDB 2.x). Guarding on presence makes this migration
-- attach where missing, skip where present, and NEVER clobber an environment's own
-- tuning (prod: 2h/1m/1m + 3d/1h/10m ; staging: 2d/1m/5m + 2d/10m/15m — both kept).

DO $$
DECLARE
    r          record;
    missing    text[] := '{}';
    other_less text[] := '{}';
BEGIN
    -- 1) Attach the rollup-critical policies ONLY where none exists yet.
    --    (jobs.hypertable_name holds the cagg's user-facing view name.)
    FOR r IN
        SELECT * FROM (VALUES
            ('public.ca_agg_equipment_values_1min',  'ca_agg_equipment_values_1min',  INTERVAL '2 hours', INTERVAL '1 minute', INTERVAL '1 minute'),
            ('public.ca_agg_equipment_values_1hour', 'ca_agg_equipment_values_1hour', INTERVAL '3 days',  INTERVAL '1 hour',   INTERVAL '30 minutes')
        ) v(cagg, view, start_off, end_off, sched)
    LOOP
        IF to_regclass(r.cagg) IS NULL THEN
            RAISE NOTICE '[#206] % absent in this database — skipped', r.cagg;
            CONTINUE;
        END IF;
        IF EXISTS (SELECT 1 FROM timescaledb_information.jobs j
                    WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
                      AND j.hypertable_name = r.view) THEN
            RAISE NOTICE '[#206] % already has a refresh policy — left as-is', r.cagg;
            CONTINUE;
        END IF;
        PERFORM add_continuous_aggregate_policy(
            r.cagg,
            start_offset      => r.start_off,
            end_offset        => r.end_off,
            schedule_interval => r.sched,
            if_not_exists     => true);
        RAISE NOTICE '[#206] attached refresh policy to % (%/%/% )', r.cagg, r.start_off, r.end_off, r.sched;
    END LOOP;

    -- 2) HARD ASSERTION — the incident cannot recur silently. Every rollup-critical
    --    ca_agg_* cagg present in this DB must now own a refresh job. (jobs.hypertable_name
    --    holds the cagg's user-facing view name for policy_refresh jobs.)
    SELECT array_agg(ca.view_name ORDER BY ca.view_name) INTO missing
      FROM timescaledb_information.continuous_aggregates ca
     WHERE ca.view_name IN ('ca_agg_equipment_values_1min','ca_agg_equipment_values_1hour')
       AND NOT EXISTS (
           SELECT 1 FROM timescaledb_information.jobs j
            WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
              AND j.hypertable_name = ca.view_name);
    IF missing IS NOT NULL AND array_length(missing, 1) > 0 THEN
        RAISE EXCEPTION '[#206] rollup-critical cagg(s) still lack a refresh policy: %  '
                        '(catch up oldest-first, then re-run — see header)', missing;
    END IF;

    -- 3) INFORMATIONAL — surface any OTHER real-time cagg without a refresh policy.
    --    NOT auto-attached (see SCOPE): needs an oldest-first catch-up at enable time.
    SELECT array_agg(ca.view_name ORDER BY ca.view_name) INTO other_less
      FROM timescaledb_information.continuous_aggregates ca
     WHERE ca.materialized_only = false
       AND ca.view_name LIKE 'ca\_%'
       AND ca.view_name NOT IN ('ca_agg_equipment_values_1min','ca_agg_equipment_values_1hour')
       AND NOT EXISTS (
           SELECT 1 FROM timescaledb_information.jobs j
            WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
              AND j.hypertable_name = ca.view_name);
    IF other_less IS NOT NULL AND array_length(other_less, 1) > 0 THEN
        RAISE NOTICE '[#206] real-time cagg(s) without a refresh policy (deferred, #208 — '
                     'catch up oldest-first before attaching): %', other_less;
    END IF;

    RAISE NOTICE '[#206] rollup-critical ca_agg_* refresh policies verified present.';
END $$;
