-- t250 — drop public.production_orders, the LAST medallion shim view (#250).
-- Pass-through view over core.production_orders. All qualified `public.production_orders`
-- consumers repointed to core (#1191): analytics-sync (14 PO-lifecycle sites), mirror-worker
-- staging.go (1; not running on staging anyway), stream-engine port-parity (1, retired tool).
-- edge-api uses BARE production_orders → resolves to core via search_path (no repoint).
-- 0 DB view deps; 0 pg_proc consumers; Superset dataset is bi.production_orders (not public).
-- Applied live on staging 2026-09-09; PO writes verified continuing in core.production_orders
-- (70 writes in the minute after the drop, 0 analytics-sync errors).
-- Completes the medallion public-shim retirement (t248 categorical, t249 OEE+facts, t250 PO).
DROP VIEW IF EXISTS public.production_orders;
