-- t-ent5-downtime-threshold-reliable-feed
--
-- Follow-up to t-ent5-counters-only-status-and-threshold, which set ent5's
-- stop_threshold_time to 1800s (30 min) as a LOSSY-FEED STOPGAP — on the theory
-- that the box→staging co-tee dropped ~40% of posts, so sub-30-min count gaps
-- couldn't be trusted as real stops.
--
-- That theory was WRONG. Verified directly: nginx logged the box's posts all 202
-- (0 rejects), the shared agent accepted 100%, and the decoder logged 0 unmapped.
-- There is essentially NO transport loss — the earlier "~40% loss" was a bad
-- 3-minute sample. So the count-silence stops at a normal threshold are REAL
-- production gaps, not artifacts, and 1800s was hiding most of them (only 23
-- stops/25h survived vs 79 at 600s).
--
-- Lower to 600s (10 min): captures genuine ~10-min+ stops for an honest downtime
-- Pareto, while still filtering brief batch-production gaps that aren't downtime.
-- Tunable per line — a continuous line can go to the 300s platform default
-- (CPAC_STOP_THRESHOLD_DEFAULT_SEC, what CPACK uses); a batch line may want higher.
--
-- SAFE: core.equipments (analytics), set_updated_at only. Scoped to ent5. Idempotent.
-- The live-minting CPAC deriver (CPAC_EVENT_LIVE_ENTERPRISES=5) picks this up on its
-- next tick; the upsert is idempotent + human-touched-guarded.

BEGIN;

UPDATE core.equipments SET stop_threshold_time = 600
 WHERE id_enterprise = 5 AND COALESCE(stop_threshold_time, 0) <> 600;

COMMIT;
