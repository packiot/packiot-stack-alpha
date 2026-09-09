-- t237 P-core — CONTRACT: drop the 17 droppable public dim shims (no remaining consumer of the
-- public.<dim> name; unqualified refs now resolve to core via the widened search_path).
--
-- KEPT PERMANENT (NOT dropped here) — each has a live consumer that references public.<dim>:
--   public.topic_routing    — chained by public.packml_register (view) + serving views (OID-bound);
--                             kept per task (compat surface).
--   public.packml_register  — VIEW (pre-existing), topology.go const refSchema="public" writes it;
--                             OID-follows to core.topic_routing. (Not in this drop set.)
--   public.production_orders — analytics-sync (LIVE dual-DB replicator) hardcodes
--                             public.production_orders in prod+staging same SQL (ON CONFLICT
--                             col-inference, view-safe); mirror-worker (dormant dual-DB) too.
--   public.equipments       — stream-engine shiftresolver hardcodes `FROM public.equipments`
--                             (literal, not RefSchema); mirror-worker dual-DB; serving.oee_score fn.
--   public.sites            — stream-engine shiftresolver `FROM public.sites`.
--   public.shift_hours      — stream-engine shiftresolver `FROM public.shift_hours`.
--   public.scrap_targets    — DB fn public.h_piot_set_scrap_target hardcodes public.scrap_targets.
--                             (NOTE: that fn has a PRE-EXISTING bug — ON CONFLICT (id_equipment) vs
--                             the (id_equipment,id_site) PK — unrelated to this reorg; shim kept so a
--                             later fix can traverse it, and to avoid turning the conflict-error into
--                             a 42P01.)
--
-- Census basis (all verified live): edge-api/src + read-api + sparkplug-decoder + barcode-service +
-- operator-gateway = 0 hardcoded public.<dim>; only 2 functions hardcode public.<dim>
-- (h_piot_set_scrap_target→scrap_targets, serving.oee_score→equipments — both KEPT); 0 SET-search_path
-- functions reference any of these 17; all view dependents are OID-bound (follow the core base).

BEGIN;
SET LOCAL lock_timeout = '3s';

DROP VIEW IF EXISTS public.areas;
DROP VIEW IF EXISTS public.enterprises;
DROP VIEW IF EXISTS public.clients;
DROP VIEW IF EXISTS public.products;
DROP VIEW IF EXISTS public.product_families;
DROP VIEW IF EXISTS public.shifts;
DROP VIEW IF EXISTS public.teams;
DROP VIEW IF EXISTS public.box_production_bridges;
DROP VIEW IF EXISTS public.oee_targets;
DROP VIEW IF EXISTS public.production_targets;
DROP VIEW IF EXISTS public.equipment_downtime_reason;
DROP VIEW IF EXISTS public.equipment_scrap_reason;
DROP VIEW IF EXISTS public.downtime_reason;
DROP VIEW IF EXISTS public.scrap_reason;
DROP VIEW IF EXISTS public.client_descriptors;
DROP VIEW IF EXISTS public.equipment_validation_shift;
DROP VIEW IF EXISTS public.shifts_exception_period;

COMMIT;
