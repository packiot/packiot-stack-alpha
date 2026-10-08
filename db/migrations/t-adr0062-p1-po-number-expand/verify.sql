-- verify for t-adr0062-p1-po-number-expand. label|value, expected in the label. Read-only.
\set ON_ERROR_STOP 1
SELECT 'V1 POs without a number: 0', count(*) FROM core.production_orders WHERE id_order_text IS NULL OR btrim(id_order_text) = '';
SELECT 'V2 duplicate (enterprise, number): 0', count(*) FROM (SELECT 1 FROM core.production_orders GROUP BY id_enterprise, id_order_text HAVING count(*) > 1) d;
SELECT 'V3 numbers that lost information vs the old text (corrections excepted): 0', count(*) FROM core.production_orders p
 WHERE p.id_order_text <> p.id_order::text AND NOT EXISTS (SELECT 1 FROM core.po_number_corrections c WHERE c.id_production_order = p.id_production_order)
   AND p.id_order_text ~ '^[0-9]+$' AND p.id_order_text::numeric = p.id_order AND p.id_order_text !~ '^0';
SELECT 'V4 D5 applied (101585550, 601585550 → 889583): 889583|889583', string_agg(id_order_text, '|' ORDER BY id_production_order)
  FROM core.production_orders WHERE id_production_order IN (101585550, 601585550);
SELECT 'V5 po_uuid present, unique, version 7: 0|t|t', count(*) FILTER (WHERE po_uuid IS NULL), count(DISTINCT po_uuid) = count(*),
       bool_and(substring(po_uuid::text, 15, 1) = '7') FROM core.production_orders;
SELECT 'V6 po_uuid time-ordered by creation (rank correlation): t', corr(r1, r2) > 0.99 FROM (
  SELECT rank() OVER (ORDER BY ts_creation) r1, rank() OVER (ORDER BY substring(po_uuid::text, 1, 13)) r2 FROM core.production_orders) z;
SELECT 'V7 trigger + unique index present: t|t', EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'production_orders_po_number'),
       EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'production_orders_id_enterprise_order_number_key');
SELECT 'I1 alphanumeric client numbers (informational)', count(*) FROM core.production_orders WHERE id_order_text ~ '[^0-9]';
