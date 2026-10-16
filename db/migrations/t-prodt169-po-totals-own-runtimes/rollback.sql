-- rollback for t-prodt169-po-totals-own-runtimes: restore the span-based v_operator_po_details_3
-- (t-operator-replace-runtime + t-no-data-status: status NOT IN (6, 20)) and its t278e comment.
-- Same relations as the live view (pg_depend); reloptions and grants kept. Idempotent.
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
            COALESCE(NULLIF(sum(por.net_production), 0::double precision), (( SELECT COALESCE(sum(ev.net_production_incr), 0::real) AS "coalesce"
                   FROM %5$s ev
                  WHERE ev.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ev.ts_value >= po.ts_start AND (po.ts_end IS NULL OR ev.ts_value <= po.ts_end)))::double precision, 0::double precision) AS net_production,
            COALESCE(NULLIF(sum(COALESCE(por.gross_production, 0::double precision) - COALESCE(por.net_production, 0::double precision)), 0::double precision), 0::double precision) AS scrap,
            COALESCE(sum(EXTRACT(epoch FROM COALESCE(upper(por.runtime_timerange), now()) - lower(por.runtime_timerange))), 0::numeric)::integer AS running_time,
            COALESCE(( SELECT sum(
                        CASE
                            WHEN ee.ts_end IS NULL THEN GREATEST(0, EXTRACT(epoch FROM now() - ee.ts_event)::integer)
                            ELSE COALESCE(ee.duration, 0)
                        END) AS sum
                   FROM %4$s ee
                  WHERE ee.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ee.ts_event >= po.ts_start AND (po.ts_end IS NULL OR ee.ts_event <= po.ts_end) AND ee.status NOT IN (6, 20) AND ee.forced_creation_system = false), 0::bigint)::integer AS downtime
           FROM %2$s po
             LEFT JOIN %3$s por ON por.id_production_order = po.id_production_order
          WHERE po.status = ANY (ARRAY[1, 2, 4])
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, po.ts_start, po.ts_end) base
$view$, opts, rel->>'production_orders', rel->>'production_orders_runtime', rel->>'equipment_events',
        rel->>'equipment_values');
  EXECUTE def;
  RAISE NOTICE 't-prodt169: v_operator_po_details_3 restored (span-based) over %', rel;
END $$;

COMMENT ON VIEW serving.v_operator_po_details_3 IS 'serving: operator-app production-order detail (net_production/scrap/running_time/downtime + derived rates) for one PO. Read by read-api /v1/operator-po-details.';

COMMIT;
