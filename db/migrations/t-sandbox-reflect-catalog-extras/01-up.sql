-- t-sandbox-reflect-catalog-extras — remove twin-native catalog rows before a reflect.
--
-- WHY (2026-09-30): ops.sandbox_reflect upserts clients / product_families / products keyed
-- on the REMAPPED id (CPACK id + offset) and never deletes sandbox extras for them (only
-- areas get an extras pass). A catalog row created natively in the twin (the sbx
-- replicator's PO enrich, a PO created in the twin with a new client/product) takes the
-- NEXT sequence id — e.g. client 'Ibá' as 1051581 instead of 3051580 — and the upsert of
-- CPACK's 'Ibá' then hits the unique (nm_client, id_enterprise) and the WHOLE heal fails
-- ("duplicate key … clients_nm_client_id_enterprise_unique"). The grace-period heal
-- retried every 5 min and kept failing, holding the twin.
--
-- WHAT: ops.sandbox_drop_catalog_extras(src, dst, off) detaches extras from the twin's POs
-- (the reflect replaces every twin PO right after, so the detach is never visible) and
-- deletes them: products → families → clients. Only rows of p_dst that are NOT the
-- remapped image of a p_src row. Called by provision-sandbox-tenant.sh before the reflect.
CREATE OR REPLACE FUNCTION ops.sandbox_drop_catalog_extras(p_src integer, p_dst integer, p_off integer)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE nc int; np int; nf int; npo int;
BEGIN
  IF p_dst < 1000000 OR p_dst = p_src THEN
    RAISE EXCEPTION 'sandbox_drop_catalog_extras: refusing dst=% (must be a sandbox id >= 1,000,000 and != src)', p_dst;
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS sbx_x_clients  (id bigint) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS sbx_x_products (id bigint) ON COMMIT DROP;
  TRUNCATE sbx_x_clients, sbx_x_products;
  INSERT INTO sbx_x_clients SELECT s.id_client FROM core.clients s
   WHERE s.id_enterprise = p_dst
     AND NOT EXISTS (SELECT 1 FROM core.clients c WHERE c.id_enterprise = p_src AND c.id_client + p_off = s.id_client);
  INSERT INTO sbx_x_products SELECT s.id_product FROM core.products s
   WHERE s.id_enterprise = p_dst
     AND NOT EXISTS (SELECT 1 FROM core.products c WHERE c.id_enterprise = p_src AND c.id_product + p_off = s.id_product);
  UPDATE core.production_orders p
     SET id_client  = CASE WHEN p.id_client  IN (SELECT id FROM sbx_x_clients)  THEN NULL ELSE p.id_client END,
         id_product = CASE WHEN p.id_product IN (SELECT id FROM sbx_x_products) THEN NULL ELSE p.id_product END
   WHERE p.id_enterprise = p_dst
     AND (p.id_client IN (SELECT id FROM sbx_x_clients) OR p.id_product IN (SELECT id FROM sbx_x_products));
  GET DIAGNOSTICS npo = ROW_COUNT;
  DELETE FROM core.products WHERE id_enterprise = p_dst AND id_product IN (SELECT id FROM sbx_x_products);
  GET DIAGNOSTICS np = ROW_COUNT;
  DELETE FROM core.product_families s
   WHERE s.id_enterprise = p_dst
     AND NOT EXISTS (SELECT 1 FROM core.product_families c WHERE c.id_enterprise = p_src AND c.id_product_family + p_off = s.id_product_family)
     AND NOT EXISTS (SELECT 1 FROM core.products x WHERE x.id_product_family = s.id_product_family);
  GET DIAGNOSTICS nf = ROW_COUNT;
  DELETE FROM core.clients WHERE id_enterprise = p_dst AND id_client IN (SELECT id FROM sbx_x_clients);
  GET DIAGNOSTICS nc = ROW_COUNT;
  RETURN format('catalog extras removed: clients %s, products %s, families %s (POs detached %s)', nc, np, nf, npo);
END $$;
COMMENT ON FUNCTION ops.sandbox_drop_catalog_extras(integer, integer, integer) IS
  'Delete twin-native clients/products/families (not the remapped image of a source row) before ops.sandbox_reflect, so a same-name native row cannot fail the reflect''s catalog upsert. See db/migrations/t-sandbox-reflect-catalog-extras.';
