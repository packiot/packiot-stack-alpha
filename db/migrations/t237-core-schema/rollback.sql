-- t237 P-core — ROLLBACK: narrow the search_path, drop all public shims + core.packml_register,
-- move the 23 dims core → public. Symmetric to 01-expand + 02-search-path (catalog-only; SET SCHEMA
-- moves rows/indexes/sequences/triggers by OID — no data at risk).
--
-- ORDER MATTERS: revert the stream-engine RefSchema=core flip back to "public" + redeploy FIRST
-- (otherwise the deployed engine reads core.<dim> with nothing there). Then run this, then restart
-- stack-pgbouncer-1.

ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, app, serving, customer_reports, public;

BEGIN;
SET LOCAL lock_timeout = '3s';

DROP VIEW IF EXISTS core.packml_register;

DROP VIEW IF EXISTS public.equipments;
DROP VIEW IF EXISTS public.sites;
DROP VIEW IF EXISTS public.areas;
DROP VIEW IF EXISTS public.enterprises;
DROP VIEW IF EXISTS public.clients;
DROP VIEW IF EXISTS public.production_orders;
DROP VIEW IF EXISTS public.products;
DROP VIEW IF EXISTS public.product_families;
DROP VIEW IF EXISTS public.shifts;
DROP VIEW IF EXISTS public.shift_hours;
DROP VIEW IF EXISTS public.teams;
DROP VIEW IF EXISTS public.topic_routing;
DROP VIEW IF EXISTS public.client_descriptors;
DROP VIEW IF EXISTS public.box_production_bridges;
DROP VIEW IF EXISTS public.oee_targets;
DROP VIEW IF EXISTS public.production_targets;
DROP VIEW IF EXISTS public.scrap_targets;
DROP VIEW IF EXISTS public.equipment_downtime_reason;
DROP VIEW IF EXISTS public.equipment_scrap_reason;
DROP VIEW IF EXISTS public.downtime_reason;
DROP VIEW IF EXISTS public.scrap_reason;
DROP VIEW IF EXISTS public.equipment_validation_shift;
DROP VIEW IF EXISTS public.shifts_exception_period;

ALTER TABLE core.equipments                SET SCHEMA public;
ALTER TABLE core.sites                     SET SCHEMA public;
ALTER TABLE core.areas                     SET SCHEMA public;
ALTER TABLE core.enterprises               SET SCHEMA public;
ALTER TABLE core.clients                   SET SCHEMA public;
ALTER TABLE core.production_orders         SET SCHEMA public;
ALTER TABLE core.products                  SET SCHEMA public;
ALTER TABLE core.product_families          SET SCHEMA public;
ALTER TABLE core.shifts                    SET SCHEMA public;
ALTER TABLE core.shift_hours               SET SCHEMA public;
ALTER TABLE core.teams                     SET SCHEMA public;
ALTER TABLE core.topic_routing             SET SCHEMA public;
ALTER TABLE core.client_descriptors        SET SCHEMA public;
ALTER TABLE core.box_production_bridges    SET SCHEMA public;
ALTER TABLE core.oee_targets               SET SCHEMA public;
ALTER TABLE core.production_targets        SET SCHEMA public;
ALTER TABLE core.scrap_targets             SET SCHEMA public;
ALTER TABLE core.equipment_downtime_reason SET SCHEMA public;
ALTER TABLE core.equipment_scrap_reason    SET SCHEMA public;
ALTER TABLE core.downtime_reason           SET SCHEMA public;
ALTER TABLE core.scrap_reason              SET SCHEMA public;
ALTER TABLE core.equipment_validation_shift SET SCHEMA public;
ALTER TABLE core.shifts_exception_period   SET SCHEMA public;

COMMIT;
