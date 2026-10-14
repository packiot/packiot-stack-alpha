-- rollback t-operator-gateway-role — remove the operator_gateway login.
--
-- FIRST point operator-gateway back at its previous credentials (revert the compose change, or set
-- OPERATOR_GATEWAY_PG_SECRET_ID in /opt/packiot/.env and recreate the container), or its next
-- connection fails. Then run this. The Secrets Manager secret packiot/<env>/operator-gateway-db-creds
-- is not touched here; delete it separately if the role is gone for good.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'operator_gateway') THEN
    -- end any live session so DROP ROLE does not fail on it
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'operator_gateway';
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM operator_gateway', current_database());
    REVOKE ALL ON FUNCTION public.current_tenant(), public.is_all_tenant() FROM operator_gateway;
    REVOKE ALL (packml_topic, id_equipment, active)  ON core.topic_routing FROM operator_gateway;
    REVOKE ALL (id_equipment, cd_equipment, id_area) ON core.equipments    FROM operator_gateway;
    REVOKE ALL (id_area, id_site)                    ON core.areas         FROM operator_gateway;
    REVOKE ALL (id_site, id_enterprise)              ON core.sites         FROM operator_gateway;
    REVOKE USAGE ON SCHEMA core, public FROM operator_gateway;
    DROP OWNED BY operator_gateway;   -- anything granted by hand later, in this database
    ALTER ROLE operator_gateway RESET ALL;
    DROP ROLE operator_gateway;
  END IF;
END $$;

COMMIT;
