-- =============================================================================
-- 0036-r8-namespace-hygiene-serving-dupes.sql
-- ADR-0036 (medallion) recommendation R8 — namespace hygiene of the numbered /
-- near-duplicate GOLD *serving* surfaces the medallion review flagged as having
-- unclear authority.
--
-- Applies to BOTH flows: packiot (F1) and packiot_shadow (F3).
-- Reference/as-executed migration — applied manually to the long-running staging
-- DBs (SSM -> docker exec timescaledb psql), NOT part of the auto-seed chain.
--
-- CONTEXT — what R8 inherited from P2 (edge-node-red PR #36, f13227e,
-- db/40-namespace-hygiene.sql), applied to staging 2026-07-22:
--   P2 already enumerated ALL of R8's h_* candidates in its 139-name manifest
--   and DELIBERATELY SKIPPED them via its guard (4) `dependent_objects_still_exist`.
--   Reason (documented in P2's header, re-verified here): every one of those
--   h_* tables is the RETURN TYPE of a legacy PostgreSQL compute function
--   (`RETURNS SETOF <table>`), which makes the function hard-depend on the
--   table's rowtype — a plain DROP TABLE errors, and those functions are STILL
--   LIVE (refdata-api datasets.go + front4 call them). P2 flagged retiring that
--   function layer as "a SEPARATE, larger cleanup" — that cleanup is NOT R8.
--
-- Therefore R8's ACTUAL droppable residual is the pair that P2 never listed and
-- that carry NO function-return-type coupling:
--   * equipment_runtime_shift_1week
--   * equipment_runtime_shift_1month
--
-- ============================ R8 VERDICT TABLE ===============================
-- (probed live 2026-07-23, BEGIN READ ONLY, both DBs, EC2 i-064bb36d1c454d861)
--
-- DROPPED-DEAD (this migration) — 0 rows both flows, no view dep, no code ref,
-- not Hasura-tracked, sole writer is the DORMANT legacy engine (see rollback):
--   equipment_runtime_shift_1week    canonical grain = equipment_runtime_1week
--                                    (F1 4504 rows / F3 2520 rows, served)
--   equipment_runtime_shift_1month   canonical grain = equipment_runtime_1month
--                                    (F1 330 rows / F3 280 rows, served)
--
-- KEPT-FOR-CONFIRMATION (NOT dropped — function-return-type coupled + live) —
-- each is `RETURNS SETOF` of a legacy piot function still called by the read
-- plane; dropping needs CASCADE (kills the function) => a function-layer
-- retirement (ADR-0031 back4/Hasura retirement), out of R8 scope:
--   h_piot_production_orders_with_runtimes_table    <- fn ...with_runtimes()
--   h_piot_production_orders_with_runtimes_table2   <- fns ...runtimes2(), ...runtimes3()
--   h_piot_production_orders_with_runtimes_table_4  <- fn ...runtimes4()   [refdata datasets.go:594 + front4]
--   h_piot_production_orders_with_runtimes_table_5  <- fn ...runtimes5()
--   h_piot_production_orders_with_runtimes_table6   <- fn ...runtimes6()
--   h_downtimes_table                               <- fn h_piot_get_downtimes()
--   h_downtimes_table_2                             <- fn h_piot_get_downtimes_equipment_level()
--   h_downtimes_table_with_sector_2                 <- fns get_downtimes_sector_2/_microstops/_events  [refdata datasets.go:444 + front4]
--   h_downtimes_table_with_sector_3                 <- fns get_downtimes_events_2/_3               [refdata datasets.go:437 + front4]
--   h_downtimes_duration_by_category                <- fn h_piot_downtimes_duration_by_category()  [refdata datasets.go:418 + front4]
-- (The canonical unsuffixed names — h_downtimes, h_production_orders_with_runtimes
--  — only exist in the packiot_refactor SANDBOX, per ADR-0012 naming-map; they
--  are NOT present in packiot / packiot_shadow, so there is no in-flow canonical
--  sibling to collapse the numbered h_* onto yet. Another reason to defer.)
--
-- SAFETY MODEL (mirrors P2 — verify-first, guarded, idempotent):
--   (1) relkind='r' (plain table) in THIS db — a view/matview of the same name
--       in the other db is skipped (IF EXISTS does NOT suppress "not a table").
--   (2) exact count(*)=0 — a non-empty table is skipped (belt-and-suspenders).
--   (3) plain DROP, no CASCADE — if any object unexpectedly depends on it the
--       drop is caught (dependent_objects_still_exist) and skipped.
--
-- WHY SAFE TO DROP (equipment_runtime_shift_1week / _1month):
--   * NOT a function return type — no fn `RETURNS SETOF` either table (verified
--     pg_proc, both DBs) => plain DROP TABLE succeeds, breaks no catalog dep.
--   * Zero rows in BOTH flows; zero view dependents (pg_depend/pg_rewrite).
--   * Zero references in front4 / back4-api / reports / refdata-api / operator /
--     oeecloud (grep, 2026-07-23). Not tracked in Hasura metadata.json; F3
--     hdb_catalog is empty.
--   * The ONLY writer is the legacy pg engine chain
--       cron job 3 `CALL piot_proc_refresh_runtime()`  ->  active = FALSE (F1)
--         -> piot_create_equipment_runtime_shift_1week()/_1month()  (INSERT ...)
--     In F3 nothing calls the create fns at all (no fn body, no job). The
--     scheduler is DISABLED as part of the DB->Go OEE migration (ADR-0014).
--
-- ROLLBACK (these are DERIVED aggregates — rebuild is cheap & lossless):
--   The dormant writer functions piot_create_equipment_runtime_shift_1week() /
--   _1month() are LEFT IN PLACE by this migration (unused, harmless). To
--   resurrect the tables, re-run the idempotent DDL from the edge-node-red seed:
--       edge-node-red/db/17-hasura-metadata-parity.sql:147  (…_1week)
--       edge-node-red/db/20-oee-engine-parity.sql:1068      (…_1month)
--   then (if the legacy engine is ever re-enabled) re-activate cron job 3 and the
--   next `piot_proc_refresh_runtime()` tick repopulates them from the canonical
--   equipment_runtime_shift base. No data is lost by the drop (both are 0-row).
--
-- FOLLOW-UP (out of R8 scope, flagged for USER): to make the drop survive a
--   fresh DB re-seed, remove those two `CREATE TABLE IF NOT EXISTS` blocks from
--   edge-node-red/db/17 + /20 in a separate edge-node-red PR (same pattern P2
--   used for its 65 live-DB drops).
--
-- Idempotent: re-running is a no-op (dropped => relkind IS NULL => CONTINUE).
-- =============================================================================

DO $r8$
DECLARE
  candidates text[] := ARRAY[
    'equipment_runtime_shift_1week',
    'equipment_runtime_shift_1month'
  ];
  t        text;
  kind     "char";
  n        bigint;
  dropped  int := 0;
  skipped  int := 0;
BEGIN
  FOREACH t IN ARRAY candidates LOOP
    -- (1) must exist as a plain table in THIS db
    SELECT c.relkind INTO kind
    FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
    WHERE ns.nspname = 'public' AND c.relname = t;

    IF kind IS NULL THEN
      CONTINUE;                                    -- absent / already dropped
    END IF;
    IF kind <> 'r' THEN
      RAISE NOTICE 'skip % (relkind=%, not a plain table)', t, kind;
      skipped := skipped + 1; CONTINUE;
    END IF;

    -- (2) must be empty
    EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n;
    IF n <> 0 THEN
      RAISE NOTICE 'skip % (has % row(s) — NOT empty, refusing to drop)', t, n;
      skipped := skipped + 1; CONTINUE;
    END IF;

    -- (3) plain DROP (no CASCADE). If something depends on it, catch & skip.
    BEGIN
      EXECUTE format('DROP TABLE public.%I', t);
      RAISE NOTICE 'dropped %', t;
      dropped := dropped + 1;
    EXCEPTION WHEN dependent_objects_still_exist THEN
      RAISE NOTICE 'skip % (has dependent objects — not dropping without CASCADE)', t;
      skipped := skipped + 1;
    END;
  END LOOP;

  RAISE NOTICE 'r8-namespace-hygiene: dropped=% skipped=% (of % candidates)',
               dropped, skipped, array_length(candidates, 1);
END
$r8$;
