-- verify for t-prodt169-po-totals-own-runtimes. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 view sums downtime over runtime windows (span predicate gone): t',
       pg_get_viewdef('serving.v_operator_po_details_3'::regclass) LIKE '%runtime_timerange%'
   AND pg_get_viewdef('serving.v_operator_po_details_3'::regclass) NOT LIKE '%ee.ts_event <= po.ts_end%'
   AND pg_get_viewdef('serving.v_operator_po_details_3'::regclass) NOT LIKE '%ev.ts_value <= po.ts_end%';
SELECT 'V2 security_invoker kept: t', coalesce('security_invoker=on' = ANY (c.reloptions), false)
  FROM pg_class c WHERE c.oid = 'serving.v_operator_po_details_3'::regclass;
SELECT 'V3 readapi_ro can SELECT: t', has_table_privilege('readapi_ro', 'serving.v_operator_po_details_3', 'SELECT');
SELECT 'V4 still excludes RUNNING and NO DATA from downtime: t',
       pg_get_viewdef('serving.v_operator_po_details_3'::regclass) ~ 'status <> ALL \(ARRAY\[6, 20\]\)';
-- Recent POs (30 d): the view's downtime equals an independent sum over each PO's own runtime windows.
WITH po AS (
  SELECT v.id_production_order, v.downtime FROM serving.v_operator_po_details_3 v
    JOIN production_orders p USING (id_production_order)
   WHERE COALESCE(p.ts_end, now()) >= now() - interval '30 days'
), own AS (
  SELECT po.id_production_order, po.downtime,
         COALESCE((SELECT sum(CASE WHEN e.ts_end IS NULL THEN GREATEST(0, EXTRACT(epoch FROM now() - e.ts_event)::int)
                                   ELSE COALESCE(e.duration, 0) END)
                     FROM production_orders_runtime w
                     JOIN production_orders p2 ON p2.id_production_order = w.id_production_order
                     JOIN equipment_events e ON e.id_equipment = COALESCE(w.id_equipment, p2.id_equipment)
                      AND w.runtime_timerange @> e.ts_event
                    WHERE w.id_production_order = po.id_production_order
                      AND e.status NOT IN (6, 20) AND e.forced_creation_system = false), 0)::int AS own_sum
    FROM po
)
SELECT 'V5 recent POs whose downtime is not the sum over their own runtimes (open ones drift by seconds): 0',
       count(*) FROM own WHERE abs(downtime - own_sum) > 120;
SELECT 'I1 recent POs compared', count(*) FROM serving.v_operator_po_details_3 v
  JOIN production_orders p USING (id_production_order) WHERE COALESCE(p.ts_end, now()) >= now() - interval '30 days';
-- informational: POs whose span holds time no runtime of theirs covers (a gap — where the old view over-counted)
SELECT 'I2 POs (status 1/2/4) with a gap between runtimes inside their span', count(*) FROM (
  SELECT r.id_production_order FROM production_orders_runtime r
    JOIN production_orders p USING (id_production_order) WHERE p.status IN (1, 2, 4)
   GROUP BY r.id_production_order
  HAVING range_agg(r.runtime_timerange) <> tstzmultirange(tstzrange(min(lower(r.runtime_timerange)),
         CASE WHEN bool_or(upper_inf(r.runtime_timerange)) THEN NULL ELSE max(upper(r.runtime_timerange)) END))
) g;
