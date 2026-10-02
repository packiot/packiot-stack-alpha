-- Sequence hygiene (found 2026-09-24 while building the sandbox reflection).
--
-- silver.equipment_events_man.id_equipment_event IDENTITY sat at 24,962 while the table's
-- max id was 162,902 (90,579 rows above it — rows inserted with explicit ids never
-- advanced the sequence). Every id-less insert (edge-api manual downtime, stream-engine
-- justify, split replay) drew an already-taken id → intermittent duplicate-key failures
-- of operator actions. Advancing a sequence changes no rows; GREATEST keeps it idempotent.
SELECT setval('silver.equipment_events_man_id_equipment_event_seq',
              GREATEST((SELECT max(id_equipment_event) FROM silver.equipment_events_man),
                       (SELECT last_value FROM silver.equipment_events_man_id_equipment_event_seq)));
-- Dimension sequences behind LEGACY ids backfilled with explicit values (products,
-- families, clients start ~21,850): csadmin creates would collide after ~21k inserts.
SELECT setval(pg_get_serial_sequence('core.clients', 'id_client'), GREATEST((SELECT max(id_client) FROM core.clients), 1));
SELECT setval(pg_get_serial_sequence('core.products', 'id_product'), GREATEST((SELECT max(id_product) FROM core.products), 1));
SELECT setval(pg_get_serial_sequence('core.product_families', 'id_product_family'), GREATEST((SELECT max(id_product_family) FROM core.product_families), 1));
-- DELIBERATELY NOT advanced: core.production_orders / gold.production_orders_runtime /
-- silver.equipment_events ids. Their max comes from reserved NAMESPACES (legacy history
-- 1e8+, sandbox reflection 5e8+, legacy events 9e15+); advancing would push NEW rows into
-- those ranges and past int4 (serving row types still declare integer). New rows keep
-- the low range; the namespaces are far above it (1e8 inserts away).
