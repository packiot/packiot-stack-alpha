-- t272 rollback — recreate customer_reports.speed (exact live structure captured pre-drop).
CREATE TABLE customer_reports.speed (customer_id integer, id_equipment integer, id_order integer, id_product integer, production_programmed bigint, production_final bigint, avg_speed numeric, final_net bigint, job_start timestamptz, product_type text);
