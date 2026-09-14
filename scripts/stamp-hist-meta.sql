-- stamp-equipment_values-meta.sql — R5. Stamp hist_meta.last_append_at for every ev_promoted
-- enterprise. Run by the append job's post-run hook (historian-staging-run-append.sh)
-- IMMEDIATELY AFTER a successful cold-store append and BEFORE refresh-equipment_values-cutover.sql,
-- so a present refresh always leaves hist_cutover.refreshed_at >= hist_meta.last_append_at.
--
-- The staleness monitor (scripts/historian-staleness-monitor.sh, R4) then flags a MISSED
-- refresh hook cheaply: last_append_at > hist_cutover.refreshed_at ⇒ the cold store grew
-- after the last boundary refresh ⇒ equipment_values_all is double-counting the newly-archived window.
--
-- Metadata-only (reads promoted_enterprise); no parquet scan. Idempotent.
INSERT INTO hist_meta (id_enterprise, last_append_at, source, updated_at)
SELECT id_enterprise, now(), 'historian-append-hook', now()
  FROM promoted_enterprise
 WHERE ev_promoted
ON CONFLICT (id_enterprise)
  DO UPDATE SET last_append_at = EXCLUDED.last_append_at,
                source         = EXCLUDED.source,
                updated_at     = now();
SELECT id_enterprise, last_append_at FROM hist_meta ORDER BY id_enterprise;
