-- t-po-runtime-fk-index — index the REFERENCING column of the PO → runtime relation.
--
-- SYMPTOM (2026-09-24): read-api `production-orders-with-runtimes` for a year window took
-- 23–25 s per call (read-api timeout 40 s → 500 under light concurrency; the sandbox
-- parity E2E hit it).
-- ROOT CAUSE: serving.production_orders_with_runtimes nests each PO's runtimes via a
-- correlated subquery `WHERE por.id_production_order = po.id_production_order` — and
-- gold.production_orders_runtime had NO index on id_production_order (only the PK on
-- id_production_order_runtime + the gist exclusion on (id_equipment, runtime_timerange)).
-- Postgres indexes the referenced side (PK) automatically, never the referencing column,
-- so every PO re-scanned all 56k runtimes of every tenant.
-- RESULT (staging, CPACK 2023, same 2,685 rows): 23,763 ms → 161 ms.
-- Applied live with CREATE INDEX CONCURRENTLY; plain IF NOT EXISTS here (22 MB table,
-- the runner is transactional) — a no-op where it already exists.
CREATE INDEX IF NOT EXISTS production_orders_runtime_id_production_order_idx
  ON gold.production_orders_runtime (id_production_order);
