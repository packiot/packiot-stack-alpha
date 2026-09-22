-- t-ent5-counters-only-status-and-threshold
--
-- Two onboarding-gap fixes for Bispharma (ent5) that together unblock LIVE
-- downtime-event derivation (ADR-0010 §10.4 promotion; the stream-engine
-- CPAC_EVENT_LIVE_ENTERPRISES=5 instance mints ent5's stops into equipment_events).
--
-- (1) status_type = 0. Bispharma is COUNTERS-ONLY (its box reads production
--     counters — no MachSpeed / StateCurrent; confirmed on mi-0114 reader.config),
--     exactly the status_type=0 class the count-silence deriver targets
--     (`WHERE e.status_type = 0` in cpac_deriver.go). But ent5's equipment were
--     bulk-imported with status_type = NULL, so the deriver's scope matched NOTHING
--     and ent5 got zero derived events (dry-run: 0 rows at NULL, 157 at 0). CPACK's
--     counters-only equipment are already 0. Set ent5 to 0.
--
-- (2) stop_threshold_time = 1800 (30 min). The deriver closes a running session
--     when count activity is silent longer than this (per-equipment; else the 300s
--     CPAC_STOP_THRESHOLD_DEFAULT_SEC). Bispharma's box→staging co-tee is LOSSY
--     (~40% of posts never reach the ingest) and cycles lines, so a *producing*
--     line can look silent for 5-10 min from NETWORK loss, not a real stop — at
--     300s that mints ~157 stops/25h, 65% of them <10 min (false churn). At 1800s
--     only the ~23 confident long stops survive (e.g. the dead L60 PLC's members).
--     This is a LOSSY-FEED STOPGAP: drop it back toward 300s once the box→cloud
--     feed is made reliable (then real micro-stops become trustworthy again).
--
-- SAFE: core.equipments (analytics), set_updated_at trigger only; no packml regen.
-- Scoped to ent5. Idempotent. Does NOT touch OEE (ent5's line OEE comes from the
-- line-lead pass, independent of status_type / these events).

BEGIN;

UPDATE core.equipments SET status_type = 0
 WHERE id_enterprise = 5 AND status_type IS DISTINCT FROM 0;

UPDATE core.equipments SET stop_threshold_time = 1800
 WHERE id_enterprise = 5 AND COALESCE(stop_threshold_time, 0) <> 1800;

COMMIT;
