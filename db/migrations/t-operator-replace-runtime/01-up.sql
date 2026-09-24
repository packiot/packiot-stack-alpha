-- t-operator-replace-runtime — expose the OPEN runtime id to the operator.
-- edge-api#(2026-08-13) made POST /api/production-orders/replace require the EXACT
-- runtime (`runtimeToReplace`) — a safety fix so a vague request can't reassign the
-- wrong runtime. It assumed front4 was the only caller; the OPERATOR's switch-PO flow
-- (ModalReplacePO → replacePo) also calls it with the old `{ idProductionOrder }` shape,
-- so every operator switch has 400'd since. The operator has no runtime id to send:
-- this APPENDS `id_production_order_runtime` (the PO's open runtime) to the view the
-- operator already polls. Appended at the END → CREATE OR REPLACE is safe; row shape of
-- existing columns unchanged; security_invoker + grants kept. Found by the sandbox E2E.
CREATE OR REPLACE VIEW serving.v_operator_po_details_3 WITH (security_invoker = on) AS
 SELECT base.id_production_order,
    base.id_equipment,
    base.id_enterprise,
    base.net_production,
    base.scrap,
    base.running_time,
    base.downtime,
    base.net_production + base.scrap AS gross,
    ( SELECT r.id_production_order_runtime
           FROM production_orders_runtime r
          WHERE r.id_production_order = base.id_production_order AND upper(r.runtime_timerange) IS NULL
          ORDER BY (lower(r.runtime_timerange)) DESC
         LIMIT 1) AS id_production_order_runtime
   FROM ( SELECT po.id_production_order,
            po.id_equipment,
            po.id_enterprise,
            po.ts_start,
            po.ts_end,
            COALESCE(NULLIF(sum(por.net_production), 0::double precision), (( SELECT COALESCE(sum(ev.net_production_incr), 0::real) AS "coalesce"
                   FROM equipment_values ev
                  WHERE ev.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ev.ts_value >= po.ts_start AND (po.ts_end IS NULL OR ev.ts_value <= po.ts_end)))::double precision, 0::double precision) AS net_production,
            COALESCE(NULLIF(sum(COALESCE(por.gross_production, 0::double precision) - COALESCE(por.net_production, 0::double precision)), 0::double precision), 0::double precision) AS scrap,
            COALESCE(sum(EXTRACT(epoch FROM COALESCE(upper(por.runtime_timerange), now()) - lower(por.runtime_timerange))), 0::numeric)::integer AS running_time,
            COALESCE(( SELECT sum(
                        CASE
                            WHEN ee.ts_end IS NULL THEN GREATEST(0, EXTRACT(epoch FROM now() - ee.ts_event)::integer)
                            ELSE COALESCE(ee.duration, 0)
                        END) AS sum
                   FROM equipment_events ee
                  WHERE ee.id_equipment = po.id_equipment AND po.ts_start IS NOT NULL AND ee.ts_event >= po.ts_start AND (po.ts_end IS NULL OR ee.ts_event <= po.ts_end) AND ee.status <> 6 AND ee.forced_creation_system = false), 0::bigint)::integer AS downtime
           FROM production_orders po
             LEFT JOIN production_orders_runtime por ON por.id_production_order = po.id_production_order
          WHERE po.status = ANY (ARRAY[1, 2, 4])
          GROUP BY po.id_production_order, po.id_equipment, po.id_enterprise, po.ts_start, po.ts_end) base;
