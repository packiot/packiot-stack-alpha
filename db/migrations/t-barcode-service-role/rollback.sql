-- rollback t-barcode-service-role — remove the barcode_service login.
--
-- FIRST point barcode-service back at its previous credentials (revert the compose change, or set
-- BARCODE_SERVICE_PG_SECRET_ID in /opt/packiot/.env and recreate the container), or its next connection
-- fails. Then run this. The secret packiot/<env>/barcode-service-db-creds is not touched; delete it
-- separately if the role is gone for good.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'barcode_service') THEN
    PERFORM pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'barcode_service';
    EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM barcode_service', current_database());
    REVOKE ALL ON FUNCTION public.current_tenant(), public.is_all_tenant() FROM barcode_service;
    REVOKE ALL (box_scan_id, id_enterprise, id_site, id_area, id_equipment, id_production_order, id_order,
                scan_type, label_seq, qty, counts_toward_total, raw_barcode, scan_uuid, ts_value)
      ON bronze.box_scans FROM barcode_service;
    REVOKE ALL (id_production_order, id_enterprise, last_label_seq, total_qty, updated_at)
      ON gold.po_box_counter FROM barcode_service;
    REVOKE ALL (id_production_order, id_enterprise, id_order)  ON core.production_orders FROM barcode_service;
    REVOKE ALL (id_equipment, id_enterprise, id_site, id_area) ON core.equipments        FROM barcode_service;
    REVOKE USAGE ON SCHEMA bronze, gold, core, public FROM barcode_service;
    DROP OWNED BY barcode_service;   -- anything granted by hand later, in this database
    ALTER ROLE barcode_service RESET ALL;
    DROP ROLE barcode_service;
  END IF;
END $$;

COMMIT;
