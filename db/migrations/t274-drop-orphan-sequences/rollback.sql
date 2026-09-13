-- t274 rollback — recreate the 5 orphan sequences (plain bigint; last_value restored
-- where they had been called). They carry no data; fidelity is nominal.
CREATE SEQUENCE public.areas_history_history_id_seq;        SELECT setval('public.areas_history_history_id_seq', 153, true);
CREATE SEQUENCE public.enterprises_history_history_id_seq;  SELECT setval('public.enterprises_history_history_id_seq', 133, true);
CREATE SEQUENCE public.equipments_history_history_id_seq;   SELECT setval('public.equipments_history_history_id_seq', 47806, true);
CREATE SEQUENCE public.sites_history_history_id_seq;        SELECT setval('public.sites_history_history_id_seq', 112, true);
CREATE SEQUENCE public.production_data_sync_enterprise_06_indice_geral_seq;
