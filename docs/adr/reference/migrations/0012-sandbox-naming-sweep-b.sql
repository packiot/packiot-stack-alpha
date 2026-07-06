-- ADR-0012 sandbox naming sweep (B) — v_* families + typo + dedupe.
--
-- Runs AFTER sweep A (depends on h_mission_control_area existing).
-- Same rules as sweep A (see 0012-naming-map.md).
--
-- OUT OF SCOPE here (owned by the Phase-4 wave plan — do not double-
-- migrate): v_13_* pooling (Wave 3), c35_v_* (Wave 3), report_*
-- (Waves 1-2 done/decided), shift_agg_from_events_v2 +
-- v_agg_equipment_values_1day_full (CAgg/contract waves).
--
-- Single-shot: run once on a freshly provisioned sandbox.

BEGIN;

-- ── operator PO list (strict 4-deep superset chain) ─────────────────
-- base ⊂ _setup ⊂ _setup_2 ⊂ _setup_3 → one canonical relation,
-- four preserved names.
DROP TABLE public.v_operator_po_list;
DROP TABLE public.v_operator_po_list_setup;
DROP TABLE public.v_operator_po_list_setup_2;
ALTER TABLE public.v_operator_po_list_setup_3 RENAME TO v_operator_po_list;
CREATE VIEW public.v_operator_po_list_setup AS
  SELECT id_production_order, id_order, nm_product_family, nm_client,
         production_programmed, ts_start, id_equipment, status,
         id_enterprise, topic, conversion_factor, equipment_setup,
         nm_product
  FROM public.v_operator_po_list;
CREATE VIEW public.v_operator_po_list_setup_2 AS
  SELECT id_production_order, id_order, nm_product_family, nm_client,
         production_programmed, ts_start, id_equipment, status,
         id_enterprise, topic, conversion_factor, equipment_setup,
         nm_product, custom_field
  FROM public.v_operator_po_list;
CREATE VIEW public.v_operator_po_list_setup_3 AS
  SELECT * FROM public.v_operator_po_list;

-- ── mission control areas: promote the _temp_fix ────────────────────
-- _temp_fix carries the corrected types (date + float8); the stable
-- name adopts them. Type change under a stable name — flag for
-- consumer verification before the prod wave.
DROP TABLE public.v_mission_control_areas_shift;
ALTER TABLE public.v_mission_control_areas_shift_temp_fix
  RENAME TO v_mission_control_areas_shift;
CREATE VIEW public.v_mission_control_areas_shift_temp_fix AS
  SELECT * FROM public.v_mission_control_areas_shift;

-- ── cross-prefix duplicate (R4) ─────────────────────────────────────
-- v_mission_control_areas_sum_from_equipment is column-identical to
-- h_mission_control_area (ex h_piot_mission_control_area_new) — one
-- concept, two prefixes. Collapse onto the h_ canonical.
DROP TABLE public.v_mission_control_areas_sum_from_equipment;
CREATE VIEW public.v_mission_control_areas_sum_from_equipment AS
  SELECT * FROM public.h_mission_control_area;

-- ── typo fix: concatenation artifact in a customer-13 stub ──────────
-- 'v_13_site_deb_labels_piot4v_13' — the 'v_13' tail is a paste bug
-- (column-identical to v_13_labels_piot4). Canonical name drops the
-- tail; the typo'd name survives as a façade (PowerBI may reference
-- it). Pooling of the v_13_* family itself stays Wave-3 scope.
ALTER TABLE public.v_13_site_deb_labels_piot4v_13
  RENAME TO v_13_site_deb_labels_piot4;
CREATE VIEW public.v_13_site_deb_labels_piot4v_13 AS
  SELECT * FROM public.v_13_site_deb_labels_piot4;

COMMIT;

\echo ''
\echo '=== sweep B verification ==='
SELECT relname,
       CASE relkind WHEN 'r' THEN 'TABLE' WHEN 'v' THEN 'VIEW' END AS kind
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public'
  AND relname IN ('v_operator_po_list', 'v_operator_po_list_setup',
    'v_operator_po_list_setup_2', 'v_operator_po_list_setup_3',
    'v_mission_control_areas_shift', 'v_mission_control_areas_shift_temp_fix',
    'v_mission_control_areas_sum_from_equipment',
    'v_13_site_deb_labels_piot4', 'v_13_site_deb_labels_piot4v_13')
ORDER BY relname;
