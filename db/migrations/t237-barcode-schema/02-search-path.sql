-- t237 P-barcode · WIDEN search_path — add `barcode` immediately before `public`
-- so unqualified reads/writes of the 4 barcode tables resolve to the real base in
-- `barcode` (shadowing the public shim), while the unqualified-CREATE landing schema
-- stays `gold` (unchanged from today — barcode is inserted AFTER the medallion
-- schemas, so this introduces NO new create-footgun this phase).
--
-- Observed by NEW sessions only. Gate step: restart stack-pgbouncer-1 (transaction
-- pooling → server conns cache the connect-time default) so all clients recycle.
-- (replay-safe 2026-10-08: the database name is the target's own, not staging's packiot_analytics)
DO $db$ BEGIN EXECUTE format('ALTER DATABASE %I', current_database()) || $q$
  SET search_path = "$user", gold, silver, bronze, barcode, public$q$; END $db$;
