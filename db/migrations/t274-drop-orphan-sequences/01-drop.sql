-- t274 — drop 5 orphan sequences in public (schema-doc necessity sweep).
--
-- Surfaced by the "why does public still exist" audit. These 5 sequences have NO
-- OWNED BY link, appear in NO column default, NO routine body, NO view definition,
-- and NO new-stack service code; their backing tables were dropped or relocated:
--   *_history_history_id_seq  → the *_history audit tables (areas/enterprises/
--                               equipments/sites_history) were dropped in the
--                               clean-schema cutover; history is not kept here.
--   production_data_sync_enterprise_06_indice_geral_seq
--                             → the per-tenant production_data_sync_enterprise_06
--                               predecessor was replaced by the pooled
--                               customer_reports.production_data_sync (#244); the
--                               pool has its own identity. (never called; NULL last_value)
--
-- NOT dropped (the audit's carried list was WRONG on these — re-verified from live):
--   equipment_oee_shift_id_seq                    → LIVE: default of gold.equipment_oee_shift.id_runtime_shift
--   equipment_validation_shift_id_validation_seq  → LIVE: default of core.equipment_validation_shift.id_validation
--
-- RESTRICT (default) — fails loudly if any dependency was missed.
DROP SEQUENCE public.areas_history_history_id_seq;
DROP SEQUENCE public.enterprises_history_history_id_seq;
DROP SEQUENCE public.equipments_history_history_id_seq;
DROP SEQUENCE public.sites_history_history_id_seq;
DROP SEQUENCE public.production_data_sync_enterprise_06_indice_geral_seq;
