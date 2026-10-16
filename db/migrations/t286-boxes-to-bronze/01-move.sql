-- t286 — move the Samples-feature box tables public -> bronze.
-- Target DB: packiot_analytics (10.10.10.89)
--
-- scanned_boxes + sample_boxes are the (currently 0-row) Samples feature's raw
-- box-scan tables — bronze-layer material by the medallion taxonomy. User decision:
-- bronze.
--
-- Consumer-transparent by search_path: the ONLY deployed consumers are edge-api's
-- samples + labels DAOs (src/data/DAO/samples, src/data/DAO/labels), which use the
-- primary PostgresAdapter (→ packiot_analytics via pgbouncer) with BARE table names
-- and NO explicit search_path, inheriting the DB-default medallion path
--   ($user, gold, silver, bronze, identity, config, ops, serving,
--    customer_reports, core, public)
-- where bronze precedes public. So bare `scanned_boxes` / `sample_boxes` resolve to
-- bronze after this move — zero code change (same mechanism already used for
-- core.*/identity.* resolution). No view, routine, or Go service references them;
-- no incoming FKs; SET SCHEMA carries PK/UNIQUE/indexes + the 2 outgoing FKs.
--
-- HARDPROOF (rolled-back tx, DB-default search_path): after SET SCHEMA bronze a bare
-- INSERT lands in bronze.{scanned_boxes,sample_boxes}; public has neither; bare
-- SELECT reads from bronze; 8 indexes + 2 FKs followed. See README.md.

ALTER TABLE public.scanned_boxes SET SCHEMA bronze;
ALTER TABLE public.sample_boxes  SET SCHEMA bronze;
