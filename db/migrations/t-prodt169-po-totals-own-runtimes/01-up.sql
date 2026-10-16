-- t-prodt169-po-totals-own-runtimes — PRODT-169 (RN-14, AC-15): the Operator's PO downtime (and the produced
-- fallback) count over the PO's OWN runtime windows, not its first-start-to-last-end span.
--
-- WHY: serving.v_operator_po_details_3 (refdata /v1/operator-po-details, the Operator's Production tab) summed
-- stops with `ts_event BETWEEN po.ts_start AND po.ts_end`. After a Replace moves R2 out of a PO that keeps R1 and
-- R3, the PO's span still covers R2, so R2's stops counted in BOTH POs (and a stop between two runtimes, in the
-- gap, counted although no runtime of the PO ran). Produced/scrap already summed the runtime rows; only the
-- produced FALLBACK (no runtime counters yet) read equipment_values over the span — same fix.
--
-- New rule: a stop (or value) belongs to the PO whose runtime window [lower, upper) on that equipment contains
-- its start (open runtime: up to now). Runtimes of one equipment never overlap (gist EXCLUDE), so nothing is
-- counted twice; an event on a runtime boundary goes to the runtime that starts there.
--
-- Column list, order and types are unchanged (CREATE OR REPLACE), reloptions (security_invoker) and grants are
-- kept. The relations are the ones the LIVE view depends on (pg_depend), so the apply does not depend on the
-- session search_path. Idempotent: re-running rebuilds the same view. Keeps the t-no-data-status predicate
-- (status NOT IN (6, 20)).
BEGIN;

DO $$
DECLARE
  v oid := 'serving.v_operator_po_details_3'::regclass;
  rel jsonb := '{}'::jsonb;
  r record;
  opts text;
  def text;
BEGIN
  FOR r IN
    SELECT DISTINCT c.relname, format('%I.%I', n.nspname, c.relname) AS q
      FROM pg_rewrite rw
      JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
      JOIN pg_class c ON c.oid = d.refobjid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE rw.ev_class = v AND c.oid <> v
       AND c.relname IN ('production_orders', 'production_orders_runtime', 'equipment_events', 'equipment_values')
  LOOP
    IF rel ? r.relname THEN
      RAISE EXCEPTION 't-prodt169: the view depends on two relations named %', r.relname;
    END IF;
    rel := rel || jsonb_build_object(r.relname, r.q);
  END LOOP;
  IF (SELECT count(*) FROM jsonb_object_keys(rel)) <> 4 THEN
    RAISE EXCEPTION 't-prodt169: expected the view to read 4 relations, found %', rel;
  END IF;

  SELECT CASE WHEN c.reloptions IS NULL THEN '' ELSE ' WITH (' || array_to_string(c.reloptions, ', ') || ')' END
    INTO opts FROM pg_class c WHERE c.oid = v;

  def := format($view$
CREATE OR REPLACE VIEW serving.v_operator_po_details_3%1$s AS
 SELECT base.id_production_order,
    base.id_equipment,
    base.id_enterprise,
    base.net_production,
    base.scrap,
    base.running_time,
    base.downtime,
    base.net_production + base.scrap AS gross,
    ( SELECT r.id_production_order_runtime
           FROM %3$s r
          WHERE r.id_production_order = base.id_production_order AND upper(r.runtime_timerange) IS NULL
          ORDER BY (lower(r.runtime_timerange)) DESC
         LIMIT 1) AS id_production_order_runtime
   FROM ( SELECT po.id_production_order,
            po.id_equipment,
            po.id_enterprise,
            po.ts_start,
            po.ts_end,
            -- produced: the runtime rows' counters; before they are computed, the raw values inside the PO's
            -- OWN runtime windows (was: inside its first-start-to-last-end span)
            COALESCE(NULLIF(sum(por.net_production), 0::double precision), (( SELECT COALESCE(sum(ev.net_production_incr), 0::real) AS "coalesce"
                   FROM %3$s w
                     JOIN %5$s ev ON ev.id_equipment = COALESCE(w.id_equipment, po.id_equipment)
                      AND ev.ts_value >= lower(w.runtime_timerange)
                      AND ev.ts_value < COALESCE(upper(w.runtime_timerange), 'infinity'::timestamptz)
                  WHERE w.id_production_order = po.id_production_order))::double precision, 0::double precision) AS net_production,
            COALESCE(NULLIF(sum(COALESCE(por.gross_production, 0::double precision) - COALESCE(por.net_production, 0::double precision)), 0::double precision), 0::double precision) AS scrap,
            COALESCE(sum(EXTRACT(epoch FROM COALESCE(upper(por.runtime_timerange), now()) - lower(por.runtime_timerange))), 0::numeric)::integer AS running_time,
            -- downtime: stops that START inside one of the PO's OWN runtime windows, on that runtime's equipment
            -- (was: inside the PO's span, which counted a moved runtime's stops in both POs — PRODT-169)
            COALESCE(( SELECT sum(
                        CASE
                            WHEN ee.ts_end IS NULL THEN GREATEST(0, EXTRACT(epoch FROM now() - ee.ts_event)::integer)
                            ELSE COALESCE(ee.duration, 0)
                        END) AS sum
                   FROM %3$s w
                     JOIN %4$s ee ON ee.id_equipment = COALESCE(w.id_equipment, po.id_equipment)
                      AND ee.ts_event >= lower(w.runtime_timerange)
                      AND ee.ts_event < COALESCE(upper(w.runtime_timerange), 'infinity'::timestamptz)
                  WHERE w.id_production_order = po.id_production_order AND ee.status NOT IN (6, 20) AND ee.forced_creation_system = false), 0::bigint)::integer AS downtime
           FROM %2$s po
             LEFT JOIN %3$s por ON por.id_production_order = po.id_production_order
          WHERE po.status = ANY (ARRAY[1, 2, 4])
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, po.ts_start, po.ts_end) base
$view$, opts, rel->>'production_orders', rel->>'production_orders_runtime', rel->>'equipment_events',
        rel->>'equipment_values');
  EXECUTE def;
  RAISE NOTICE 't-prodt169: v_operator_po_details_3 rebuilt over %', rel;
END $$;

COMMENT ON VIEW serving.v_operator_po_details_3 IS
  'serving: operator PO totals (refdata /v1/operator-po-details): produced, scrap, running time and downtime summed over the PO''s OWN runtime windows (PRODT-169), never its first-start-to-last-end span; id_production_order_runtime = the open runtime.';

COMMIT;
