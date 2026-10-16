-- t237 P-views · WIDEN search_path — add `serving`, `customer_reports` immediately
-- before `public` so unqualified reads of the 15 moved views resolve to their real
-- base (shadowing the public shim). Placed AFTER the medallion/dim schemas and BEFORE
-- public → the unqualified-CREATE landing schema stays `gold` (unchanged; both new
-- schemas are views-only, no service bootstraps a table there → NO new create-footgun).
--
-- Observed by NEW sessions only. Gate step: restart stack-pgbouncer-1 (transaction
-- pooling → server conns cache the connect-time default) so every client recycles.
ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, app, serving, customer_reports, public;
