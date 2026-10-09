-- t243 (naming) · rename core.topic_routing's PK column off the OLD table name.
-- The column id_packml_register + constraint packml_register_pkey were named after
-- the pre-rename `packml_register` table; the base table is now `topic_routing`.
--
-- ZERO service impact (hardproofed): every consumer (mirror-worker-go, sparkplug-
-- decoder) reads the PK via the `packml_register` COMPAT VIEW, and a base-column
-- rename auto-propagates to dependent views while KEEPING their output column name
-- (proven: view still exposes `id_packml_register`). The 2 serving views + both
-- packml_register compat views re-point automatically. 0 inbound FKs. No deploy.
BEGIN;
ALTER TABLE core.topic_routing RENAME COLUMN id_packml_register TO id_topic_route;
ALTER TABLE core.topic_routing RENAME CONSTRAINT packml_register_pkey TO topic_routing_pkey;
COMMIT;
