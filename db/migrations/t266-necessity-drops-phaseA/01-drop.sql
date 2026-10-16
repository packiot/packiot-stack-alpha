-- t266 Phase A — necessity-audit drops (fully reversible, zero-consumer proven).
-- Only the two objects that need NO code change and have a trivially-restorable DDL:
--  • ops.function_execution_log — the monitoramento→rename orphan (#243): zero writers,
--    readers, dependents, rows. Instrumentation belongs in the observability stack
--    (Tempo/Prometheus, #180), not a dead table.
--  • serving.v_po_box_totals — an on-the-fly box_scans aggregation superseded by the
--    materialized gold.po_box_counter (what barcode-service reads/writes). Zero readers
--    (stale README line only).
-- Deferred to later phases (need code-deploy or cagg-recreate rollback): cagg chain
-- (equipment_categorical_10min, equipment_metrics_10min/1hour/1day), writer-stop drops
-- (silver.equipment_live_hour/week, site-day chain, customer_reports.speed + speed33.go).
DROP TABLE IF EXISTS ops.function_execution_log;
DROP VIEW  IF EXISTS serving.v_po_box_totals;
