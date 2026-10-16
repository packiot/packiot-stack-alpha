-- t-sandbox-hold-mode — tell the replicator WHY the twin is held (2026-09-30).
--
-- WHY: during a HEAL the twin is held too (healing_since). The replicator treated it like a
-- hands-on session: advance the cursor without applying. But the heal's reflect copies CPACK's
-- state at ONE instant, and a CPACK action replicated into ent 3 AFTER that instant but while
-- the heal still ran was skipped for the twin AND missed by the reflect → lost. Seen live:
-- CPACK's open L6-PTH stop at 22:09 never reached the twin (heal 22:10–22:14); the
-- sandbox-front4 "live downtimes mirror CPACK" gate failed on exactly that one event.
--
-- MODES: 'session' (a person's changes are held) → skip + advance, the heal reflects it all;
--        'healing' (a heal is running)          → PAUSE: do not fetch or advance; after the heal
--                                                  the backlog replays on top of the reflection
--                                                  (idempotent natural-key handlers);
--        'none'.
CREATE OR REPLACE FUNCTION ops.sandbox_hold_mode(p_ent integer)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce((
    SELECT CASE WHEN healing_since IS NOT NULL AND healing_since > now() - interval '1 hour' THEN 'healing'
                WHEN held THEN 'session'
                ELSE 'none' END
      FROM ops.sandbox_hold_status WHERE id_enterprise = p_ent), 'none')
$$;
COMMENT ON FUNCTION ops.sandbox_hold_mode(integer) IS
  'none | session (hands-on changes held: replicator skips + advances) | healing (heal running: replicator pauses without advancing). See db/migrations/t-sandbox-hold-mode.';
