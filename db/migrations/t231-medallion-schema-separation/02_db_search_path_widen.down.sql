-- t231 · PHASE 2 (search_path) — reversal.
-- Restores the pre-t231 state: no DB-level search_path override (the DB kept
-- only track_functions=pl; session default was "$user", public).
ALTER DATABASE packiot_analytics RESET search_path;
