-- =============================================================================
-- F3 (packiot_analytics) fix: v_report_downtimes returns 0 rows for ALL tenants
-- =============================================================================
-- ROOT CAUSE (evidence-backed, CPACK id_enterprise=3):
--   The report joined every downtime event to production_orders_runtime and then
--   FILTERED on `por.runtime_timerange @> lower(shift.ts_range)` in an INNER join.
--   Two compounding defects made this return exactly 0 rows on F3:
--
--   1. Wrong anchor: the PO was matched to the SHIFT's start instant
--      (`lower(shift.ts_range)`), not to the downtime's own time. A PO only matched
--      if it happened to span the exact shift boundary. On F3 the only shift-starts
--      that fall inside a PO runtime belong to *recent* shifts whose downtimes are
--      still OPEN (ts_end / duration = NULL) -> 503 such rows, ALL null-duration.
--   2. Those 503 rows were then dropped by `duration >= COALESCE(stop_threshold_time,0)`
--      because `NULL >= 0` = NULL. Net: 0 rows. (Diagnosed: without the threshold the
--      current predicate yields 503; with it, 0.) Only 23 ent-3 events are BOTH
--      threshold-passing AND inside a PO, so an INNER join can never build a report
--      on F3 -- production_orders_runtime coverage is sparse on the new stack
--      (46 PO rows vs 19,098 downtimes; ~2.8% of events fall in a PO runtime).
--
--   F1 (packiot) has a BYTE-IDENTICAL definition yet returns 2545 rows only because
--   its historical events are CLOSED (have durations) and their shift-starts happen
--   to land inside POs. The SQL is fragile; F3's data shape exposes it.
--
-- FIX (root cause, not a band-aid):
--   The production_orders join exists ONLY to label each downtime with its order
--   (`op`). It must ANNOTATE, not FILTER. So:
--     * production_orders_runtime / production_orders become LEFT JOINs
--       (a downtime with no active order is still a downtime -> op = NULL).
--     * the PO is matched to the DOWNTIME'S OWN time:
--       `por.runtime_timerange @> eventos.ts_event`  (correct attribution;
--       PO runtimes are non-overlapping per equipment, so <= 1 match, no fan-out).
--     * the erroneous `por.runtime_timerange @> lower(shift.ts_range)` WHERE clause
--       is removed.
--   Everything else (status=10, event_should_be_displayed, the point-in-shift-window
--   match, and the duration/threshold filter) is UNCHANGED -- those are shared with
--   the working F1 view and are not the regression. The column list (op, linha,
--   turno, inicio, fim, duracao, maquina, codigo_categoria, codigo_subcategoria,
--   descricao_categoria, descricao_subcategoria, anotacao, id_enterprise, ts_value)
--   is preserved EXACTLY for the refdata-api `report-downtimes` dataset contract.
--
-- RESULT (F3, id_enterprise=3): 0 -> 2218 downtime rows.
--   `op` is currently NULL for these rows because F3's sparse production_orders_runtime
--   does not yet overlap the closed/threshold-passing downtimes; as PO-runtime
--   coverage on the new stack improves, `op` populates automatically with no further
--   view change. This is data-limited, not view-broken.
--
-- Idempotent: CREATE OR REPLACE. Column set/order/types are unchanged, so REPLACE is
-- accepted by PostgreSQL.
-- =============================================================================

CREATE OR REPLACE VIEW public.v_report_downtimes AS
 SELECT po.id_order AS op,
    e.nm_equipment AS linha,
    shift.cd_shift AS turno,
    eventos.ts_event AS inicio,
    eventos.ts_end AS fim,
    eventos.duration AS duracao,
    eventos.cd_machine AS maquina,
    eventos.cd_category AS codigo_categoria,
    eventos.cd_subcategory AS codigo_subcategoria,
    eventos.desc_category AS descricao_categoria,
    eventos.desc_subcategory AS descricao_subcategoria,
    eventos.txt_downtime_notes AS anotacao,
    eventos.id_enterprise,
    shift.ts_value
   FROM ( SELECT equipment_events.id_equipment,
            equipment_events.ts_event,
            equipment_events.status,
            equipment_events.id_equipment_event,
            equipment_events.txt_downtime_notes,
            equipment_events.idle,
            equipment_events.idle_processed,
            equipment_events.forced_creation_system,
            equipment_events.fault,
            equipment_events.fault_processed,
            equipment_events.cd_machine,
            equipment_events.cd_category,
            equipment_events.cd_subcategory,
            equipment_events.change_over,
            equipment_events.planned_downtime,
            equipment_events.ts_end,
            equipment_events.duration,
            equipment_events.id_enterprise,
            equipment_events.desc_category,
            equipment_events.desc_subcategory,
            equipment_events.cd_category_client,
            equipment_events.cd_subcategory_client,
            equipment_events.last_update,
            equipment_events.ignore_cost
           FROM equipment_events
        UNION ALL
         SELECT equipment_events_man.id_equipment,
            equipment_events_man.ts_event,
            equipment_events_man.status,
            equipment_events_man.id_equipment_event,
            equipment_events_man.txt_downtime_notes,
            equipment_events_man.idle,
            equipment_events_man.idle_processed,
            equipment_events_man.forced_creation_system,
            equipment_events_man.fault,
            equipment_events_man.fault_processed,
            equipment_events_man.cd_machine,
            equipment_events_man.cd_category,
            equipment_events_man.cd_subcategory,
            equipment_events_man.change_over,
            equipment_events_man.planned_downtime,
            equipment_events_man.ts_end,
            equipment_events_man.duration,
            equipment_events_man.id_enterprise,
            equipment_events_man.desc_category,
            equipment_events_man.desc_subcategory,
            equipment_events_man.cd_category_client,
            equipment_events_man.cd_subcategory_client,
            equipment_events_man.last_update,
            equipment_events_man.ignore_cost
           FROM equipment_events_man) eventos
     JOIN equipment_runtime_shift shift ON eventos.id_equipment = shift.id_equipment
     JOIN equipments e ON eventos.id_equipment = e.id_equipment
     LEFT JOIN production_orders_runtime por ON por.id_equipment = eventos.id_equipment
          AND por.runtime_timerange @> eventos.ts_event
     LEFT JOIN production_orders po ON po.id_production_order = por.id_production_order
  WHERE eventos.status = 10
    AND e.event_should_be_displayed = true
    AND eventos.ts_event >= lower(shift.ts_range)
    AND eventos.ts_event <= upper(shift.ts_range)
    AND eventos.duration >= COALESCE(e.stop_threshold_time, 0);
