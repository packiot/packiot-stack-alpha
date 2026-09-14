-- refresh-ee-cutover.sql — recompute the HOT-ANCHORED EE boundary.
-- UNLIKE refresh-equipment_values-cutover.sql (which scans the cold `equipment_values` parquet and so MUST
-- be a top-level statement), this reads ONLY the hot FDW (live.equipment_events) —
-- a cheap Postgres aggregate, no pg_duckdb parquet scan — so it is safe anywhere.
--
-- cutover_ts = min(hot ts_event) per enterprise. COLD owns ts_event < cutover_ts,
-- HOT owns ts_event >= cutover_ts (see 10-historian-gateway.sh EE header).
-- Re-run whenever the hot EE earliest event can change for a promoted tenant
-- (e.g. another deep-history backfill like f3-phasec-history-backfill.sql).
-- t271: only ee_promoted enterprises — the cutover gates the promoted cold side only.
INSERT INTO ev_events_cutover (id_enterprise, cutover_ts, refreshed_at)
SELECT lv.id_enterprise, min(lv.ts_event)::timestamp, now()
  FROM live.equipment_events lv
  JOIN promoted_enterprise p ON p.id_enterprise = lv.id_enterprise AND p.ee_promoted
 WHERE lv.id_enterprise IS NOT NULL
 GROUP BY lv.id_enterprise
ON CONFLICT (id_enterprise)
  DO UPDATE SET cutover_ts = EXCLUDED.cutover_ts, refreshed_at = now();
DELETE FROM ev_events_cutover
 WHERE id_enterprise NOT IN (SELECT id_enterprise FROM promoted_enterprise WHERE ee_promoted);
SELECT id_enterprise, cutover_ts FROM ev_events_cutover ORDER BY id_enterprise;
