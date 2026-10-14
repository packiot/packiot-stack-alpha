-- t-sandbox-running-po-runtime — a sandbox heal never leaves a Running PO without an
-- open runtime window (PRODT-164 AC-01/AC-03; spec docs/specs/PRODT-157-operator-app.md).
--
-- WHY: ops.sandbox_reflect copies CPACK staging's POs and runtime windows as they are.
-- When the source carries the known invariant violation "status = 2 but no open
-- production_orders_runtime row" (legacy-mirror lag, a window closed by a converge, a
-- runtime the reflect's ON CONFLICT DO NOTHING dropped), the twin inherits it: the
-- Operator shows no running PO while create-and-start refuses "Cannot start an order
-- without finish the current one!" (PRODT-163, SANDBOX-CPACK L5, 2026-10-12). Nothing in
-- the sandbox repairs it while a tester holds the twin (the PO reconciler stands down).
--
-- WHAT: ops.sandbox_fix_running_without_runtime(p_dst) — for every Running PO of the
-- SANDBOX p_dst with no open window:
--   * the line is free (no open window on its equipment) → open one from
--     greatest(ts_start, the equipment's last runtime end), capped at now(): the PO keeps
--     running, like its source, and counts production from there;
--   * another open window holds the line → the PO is Paused at its own last window end
--     (or ts_start + 1 s), so the line has exactly one running owner.
-- Returns 'opened=N paused=M'. Refuses any enterprise below 1,000,000 (CPACK ent 3 and
-- every real tenant): AC-04, CPACK-Staging is never touched. Idempotent: a second call
-- finds nothing to do.
--
-- Called by scripts/provision-sandbox-tenant.sh right after the reflect (guarded by
-- to_regprocedure, so heals keep working on a DB without this migration). Applying
-- this file changes NO data by itself.
CREATE OR REPLACE FUNCTION ops.sandbox_fix_running_without_runtime(p_dst integer)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  r record; n_open int := 0; n_pause int := 0; lower_ts timestamptz; end_ts timestamptz;
BEGIN
  IF p_dst IS NULL OR p_dst < 1000000 THEN
    RAISE EXCEPTION 'sandbox_fix_running_without_runtime: refusing enterprise % (sandbox ids are >= 1,000,000)', p_dst;
  END IF;
  FOR r IN
    SELECT p.id_production_order, p.id_equipment, p.ts_start
      FROM core.production_orders p
     WHERE p.id_enterprise = p_dst AND p.status = 2
       AND NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime w
                        WHERE w.id_production_order = p.id_production_order
                          AND upper(w.runtime_timerange) IS NULL)
     ORDER BY p.id_production_order
     FOR UPDATE OF p
  LOOP
    IF NOT EXISTS (SELECT 1 FROM gold.production_orders_runtime w
                    WHERE w.id_equipment = r.id_equipment AND upper(w.runtime_timerange) IS NULL) THEN
      SELECT greatest(coalesce(r.ts_start, now()), coalesce(max(upper(w.runtime_timerange)), '-infinity'))
        INTO lower_ts
        FROM gold.production_orders_runtime w WHERE w.id_equipment = r.id_equipment;
      IF lower_ts <= now() THEN
        INSERT INTO gold.production_orders_runtime (id_production_order, runtime_timerange, id_equipment, recalc_needed)
        VALUES (r.id_production_order, tstzrange(lower_ts, NULL, '[)'), r.id_equipment, true);
        UPDATE core.production_orders SET recalc_needed = true WHERE id_production_order = r.id_production_order;
        n_open := n_open + 1;
        CONTINUE;
      END IF;
    END IF;
    SELECT max(upper(w.runtime_timerange)) INTO end_ts
      FROM gold.production_orders_runtime w WHERE w.id_production_order = r.id_production_order;
    end_ts := greatest(coalesce(end_ts, r.ts_start + interval '1 second', now()), r.ts_start + interval '1 second');
    UPDATE core.production_orders
       SET status = 4, ts_end = end_ts, recalc_needed = true
     WHERE id_production_order = r.id_production_order;
    n_pause := n_pause + 1;
  END LOOP;
  RETURN format('opened=%s paused=%s', n_open, n_pause);
END $$;
COMMENT ON FUNCTION ops.sandbox_fix_running_without_runtime(integer) IS
  'PRODT-164: give every Running PO of a SANDBOX tenant (>= 1,000,000) an open runtime window, or pause it when another window holds the line. Called after ops.sandbox_reflect by the heal; idempotent; refuses real tenants.';
