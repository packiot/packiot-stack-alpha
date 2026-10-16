-- t237 P-core · WIDEN search_path — add `core` immediately before `public`.
--
-- Placement: core goes LAST before public (after the medallion/reorg schemas), NOT first. Two
-- reasons: (1) the unqualified-CREATE-landing schema stays `gold` (the first existing schema on the
-- path) — unchanged, no new footgun for any stray unqualified migration; (2) core dim names are
-- unique (they exist only in core + the public shim), so a single occurrence of `core` anywhere on
-- the path before `public` makes an unqualified dim ref resolve to the core BASE (shadowing the shim)
-- — which is exactly what we want post-contract.
--
-- After applying this, RESTART stack-pgbouncer-1 so its cached server connections pick up the new
-- default (transaction pooling caches the connect-time search_path; a client-app restart alone would
-- not recycle the pooled server conns).

ALTER DATABASE packiot_analytics
  SET search_path = "$user", gold, silver, bronze, barcode, app, serving, customer_reports, core, public;
