-- t237 P-barcode · WIDEN search_path — add `barcode` immediately before `public`
-- so unqualified reads/writes of the 4 barcode tables resolve to the real base in
-- `barcode` (shadowing the public shim), while the unqualified-CREATE landing schema
-- stays `gold` (unchanged from today — barcode is inserted AFTER the medallion
-- schemas, so this introduces NO new create-footgun this phase).
--
-- Observed by NEW sessions only. Gate step: restart stack-pgbouncer-1 (transaction
-- pooling → server conns cache the connect-time default) so all clients recycle.
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, public;
