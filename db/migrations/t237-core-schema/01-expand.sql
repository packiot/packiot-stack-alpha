-- t237 P-core — EXPAND: move the 23 dimension/reference tables public → core + auto-updatable
-- public shim views. HIGHEST RISK: this is the LIVE control-plane write path (edge-api PO control,
-- downtime justify, packml/topic_routing upserts) + the hot SparkPlug ingest router (topic_routing).
--
-- ATOMIC (one tx): every table moves and gets its shim together, so OLD pooled connections (edge-api
-- via pgbouncer, still on the pre-core search_path until the bounce) never observe a missing relation
-- — their unqualified refs resolve through the public shim → core base. lock_timeout=3s + atomic
-- rollback: if any AccessExclusive queues behind a live PO write / ingest read past 3s, the whole tx
-- rolls back cleanly and we retry.
--
-- SET SCHEMA auto-moves owned sequences (serial PKs) + indexes + triggers by OID — do NOT move them
-- explicitly (P-barcode lesson). All DB-internal view dependents are OID-bound and follow the base.
--
-- packml_register CHAIN: packml_register is a VIEW over the base table topic_routing (medallion
-- rename). Moving topic_routing→core keeps public.packml_register valid (OID-bound to the moved
-- base). We ALSO mint core.packml_register (SELECT * FROM core.topic_routing) because stream-engine,
-- after the RefSchema→core flip, reads `core.packml_register` (%[2]s.packml_register). Both
-- public.packml_register (topology.go const refSchema="public" writes + serving views) and
-- public.topic_routing stay as PERMANENT compat shims.

CREATE SCHEMA IF NOT EXISTS core;

BEGIN;
SET LOCAL lock_timeout = '3s';

-- 23 dims → core
ALTER TABLE public.equipments                SET SCHEMA core;
ALTER TABLE public.sites                     SET SCHEMA core;
ALTER TABLE public.areas                     SET SCHEMA core;
ALTER TABLE public.enterprises               SET SCHEMA core;
ALTER TABLE public.clients                   SET SCHEMA core;
ALTER TABLE public.production_orders         SET SCHEMA core;
ALTER TABLE public.products                  SET SCHEMA core;
ALTER TABLE public.product_families          SET SCHEMA core;
ALTER TABLE public.shifts                    SET SCHEMA core;
ALTER TABLE public.shift_hours               SET SCHEMA core;
ALTER TABLE public.teams                     SET SCHEMA core;
ALTER TABLE public.topic_routing             SET SCHEMA core;
ALTER TABLE public.client_descriptors        SET SCHEMA core;
ALTER TABLE public.box_production_bridges    SET SCHEMA core;
ALTER TABLE public.oee_targets               SET SCHEMA core;
ALTER TABLE public.production_targets        SET SCHEMA core;
ALTER TABLE public.scrap_targets             SET SCHEMA core;
ALTER TABLE public.equipment_downtime_reason SET SCHEMA core;
ALTER TABLE public.equipment_scrap_reason    SET SCHEMA core;
ALTER TABLE public.downtime_reason           SET SCHEMA core;
ALTER TABLE public.scrap_reason              SET SCHEMA core;
ALTER TABLE public.equipment_validation_shift SET SCHEMA core;
ALTER TABLE public.shifts_exception_period   SET SCHEMA core;

-- auto-updatable public shim views (bridge the pgbouncer-recycle window; a subset stays permanent)
CREATE VIEW public.equipments                AS SELECT * FROM core.equipments;
CREATE VIEW public.sites                     AS SELECT * FROM core.sites;
CREATE VIEW public.areas                     AS SELECT * FROM core.areas;
CREATE VIEW public.enterprises               AS SELECT * FROM core.enterprises;
CREATE VIEW public.clients                   AS SELECT * FROM core.clients;
CREATE VIEW public.production_orders         AS SELECT * FROM core.production_orders;
CREATE VIEW public.products                  AS SELECT * FROM core.products;
CREATE VIEW public.product_families          AS SELECT * FROM core.product_families;
CREATE VIEW public.shifts                    AS SELECT * FROM core.shifts;
CREATE VIEW public.shift_hours               AS SELECT * FROM core.shift_hours;
CREATE VIEW public.teams                     AS SELECT * FROM core.teams;
CREATE VIEW public.topic_routing             AS SELECT * FROM core.topic_routing;
CREATE VIEW public.client_descriptors        AS SELECT * FROM core.client_descriptors;
CREATE VIEW public.box_production_bridges    AS SELECT * FROM core.box_production_bridges;
CREATE VIEW public.oee_targets               AS SELECT * FROM core.oee_targets;
CREATE VIEW public.production_targets        AS SELECT * FROM core.production_targets;
CREATE VIEW public.scrap_targets             AS SELECT * FROM core.scrap_targets;
CREATE VIEW public.equipment_downtime_reason AS SELECT * FROM core.equipment_downtime_reason;
CREATE VIEW public.equipment_scrap_reason    AS SELECT * FROM core.equipment_scrap_reason;
CREATE VIEW public.downtime_reason           AS SELECT * FROM core.downtime_reason;
CREATE VIEW public.scrap_reason              AS SELECT * FROM core.scrap_reason;
CREATE VIEW public.equipment_validation_shift AS SELECT * FROM core.equipment_validation_shift;
CREATE VIEW public.shifts_exception_period   AS SELECT * FROM core.shifts_exception_period;

-- packml_register compat: mint core.packml_register for stream-engine's RefSchema=core read.
-- (public.packml_register already exists and OID-follows to core.topic_routing — left untouched.)
CREATE VIEW core.packml_register AS SELECT * FROM core.topic_routing;

COMMIT;
