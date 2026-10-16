-- t-sandbox-grace-hold — a GRACE PERIOD for hands-on changes in the SANDBOX-CPACK twin
-- (ent 2000003), then an automatic self-heal back to a live CPACK-staging reflection.
--
-- WHY: the twin is an exact live mirror of CPACK staging (fanout telemetry +
-- legacy-replicator-sbx for operator actions + ops.sandbox_reflect nightly). A person
-- testing PO actions / justifications / config edits on it needs those changes to STAY
-- while they work — but the replicator keeps replaying CPACK's own PO starts/stops into
-- the twin (it would fight them), and the nightly/E2E heal would wipe them mid-session.
--
-- MODEL (derived from data — no app changes needed to detect a session):
--   * a CHANGE = an identity.user_logs row for the twin whose category is not a read
--     (edge-api's audit logger writes one for every request, operator/csadmin/front4).
--     Unknown categories COUNT as changes: an extra hold only delays a heal; a missed
--     one would wipe someone's work.
--   * HELD     = a change newer than the last heal (or a heal in progress, or a manual
--     hold_until in the future). While held: legacy-replicator-sbx advances its cursor
--     WITHOUT applying (SANDBOX_HOLD_ENABLED), its reconcilers skip, and
--     provision-sandbox-tenant.sh --heal refuses unless the hold is due (or forced).
--     Telemetry (fanout) keeps flowing, so a PO started in the twin accrues live counts.
--   * DUE      = held AND now() >= greatest(last change + grace, hold_until).
--     scripts/sandbox-session.sh tick (systemd timer, every 5 min) runs the heal when due:
--     config re-clone + ops.sandbox_reflect (POs, runtimes, events, manual events,
--     reasons) = CPACK staging again; then the hold releases and the replicator resumes
--     (its PO/manual reconcilers close any gap left while it skipped).
-- Idempotent. Only ops.* objects + one index on identity.user_logs.

CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.sandbox_state (
    id_enterprise    integer PRIMARY KEY CHECK (id_enterprise >= 1000000),
    src_enterprise   integer NOT NULL,
    grace            interval NOT NULL DEFAULT interval '4 hours',
    hold_until       timestamptz,          -- manual extension ("keep my changes until …")
    last_heal_at     timestamptz,          -- START time of the last successful heal
    last_heal_status text,
    healing_since    timestamptz,          -- set while a heal runs (hold stays on)
    updated_at       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.sandbox_state IS
  'Sandbox twin grace-period state (t-sandbox-grace-hold). One row per twin. grace = how long after the LAST hands-on change the twin self-heals back to its source; hold_until = manual extension; last_heal_at = start of the last successful heal (changes after it re-arm the hold).';

INSERT INTO ops.sandbox_state (id_enterprise, src_enterprise, last_heal_at, last_heal_status)
VALUES (2000003, 3, now(), 'seeded by t-sandbox-grace-hold')
ON CONFLICT (id_enterprise) DO NOTHING;

-- The hold query reads the newest change per twin — needs (id_enterprise, ts_log).
CREATE INDEX IF NOT EXISTS user_logs_enterprise_ts_idx ON identity.user_logs (id_enterprise, ts_log DESC);

-- Reads never hold the twin. Everything else (created/edited/deleted/justified/started/
-- stored/saved/recorded/…, and any NEW category) does.
CREATE OR REPLACE FUNCTION ops.sandbox_is_change(p_category text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_category IS NOT NULL
     AND p_category !~* '(-listed|-list|-read|-fetched|-downloaded|-checked|-viewed|-simulated|-status|_status|-opened|_open|guest-token\.mint|-exported|-previewed|-searched|\.detailed|_list_runs|_connect|_health|_logs|[_-]plan|_session_start|_session_stop)$'
$$;
COMMENT ON FUNCTION ops.sandbox_is_change(text) IS
  'True when an identity.user_logs category is a MUTATION (holds the sandbox). Read-type suffixes are excluded; unknown categories count as changes (fail-safe: delay a heal rather than wipe work).';

CREATE OR REPLACE VIEW ops.sandbox_hold_status AS
SELECT s.id_enterprise,
       s.src_enterprise,
       s.grace,
       s.hold_until,
       s.last_heal_at,
       s.last_heal_status,
       s.healing_since,
       c.last_change_at,
       c.last_change,
       (c.last_change_at IS NOT NULL OR s.healing_since IS NOT NULL
        OR coalesce(s.hold_until > now(), false))                          AS held,
       CASE WHEN c.last_change_at IS NOT NULL OR coalesce(s.hold_until > now(), false)
            THEN greatest(c.last_change_at + s.grace, s.hold_until) END  AS heal_due_at,
       -- a heal "running" for over an hour crashed: due again so the tick retries it
       ((s.healing_since IS NULL OR s.healing_since < now() - interval '1 hour')
        AND (c.last_change_at IS NOT NULL OR coalesce(s.hold_until > now(), false))
        AND now() >= greatest(c.last_change_at + s.grace, s.hold_until))  AS heal_due
  FROM ops.sandbox_state s
  LEFT JOIN LATERAL (
        SELECT u.ts_log AS last_change_at, u.category AS last_change
          FROM identity.user_logs u
         WHERE u.id_enterprise = s.id_enterprise
           AND u.ts_log > coalesce(s.last_heal_at, '-infinity')
           AND ops.sandbox_is_change(u.category)
         ORDER BY u.ts_log DESC
         LIMIT 1) c ON true;
COMMENT ON VIEW ops.sandbox_hold_status IS
  'Per-twin hold: held (replicator pauses, heals refuse), heal_due_at, heal_due (the 5-min tick heals now). Derived from identity.user_logs changes since last_heal_at.';

-- Cheap single-value check for the replicator (fail-open to "not held" is the CALLER's
-- job: a missing row = not a managed twin).
CREATE OR REPLACE FUNCTION ops.sandbox_held(p_ent integer)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT held FROM ops.sandbox_hold_status WHERE id_enterprise = p_ent), false)
$$;

-- Heal bookkeeping (called by provision-sandbox-tenant.sh --heal / sandbox-session.sh).
-- begin: refuses (raises) while a hold is active and not due, unless p_force.
CREATE OR REPLACE FUNCTION ops.sandbox_heal_begin(p_ent integer, p_force boolean DEFAULT false)
RETURNS timestamptz LANGUAGE plpgsql AS $$
DECLARE st record; t timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO st FROM ops.sandbox_hold_status WHERE id_enterprise = p_ent;
  IF NOT FOUND THEN
    RETURN t;   -- unmanaged twin: no hold semantics
  END IF;
  IF st.healing_since IS NOT NULL AND st.healing_since > now() - interval '1 hour' AND NOT p_force THEN
    RAISE EXCEPTION 'sandbox %: a heal is already running since %', p_ent, st.healing_since;
  END IF;
  IF st.held AND NOT coalesce(st.heal_due, false) AND NOT p_force THEN
    RAISE EXCEPTION 'sandbox % is HELD (last change "%" at %, heal due at %) — refusing to wipe an active session. Wait, run "sandbox-session.sh heal-now", or set SANDBOX_HEAL_FORCE=1.',
      p_ent, st.last_change, st.last_change_at, st.heal_due_at;
  END IF;
  UPDATE ops.sandbox_state SET healing_since = t, updated_at = now() WHERE id_enterprise = p_ent;
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION ops.sandbox_heal_end(p_ent integer, p_ok boolean, p_note text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE ops.sandbox_state
     SET last_heal_at     = CASE WHEN p_ok THEN coalesce(healing_since, now()) ELSE last_heal_at END,
         hold_until       = CASE WHEN p_ok THEN NULL ELSE hold_until END,
         last_heal_status = CASE WHEN p_ok THEN 'ok' ELSE 'failed' END
                            || coalesce(': ' || p_note, '') || ' @ ' || now()::text,
         healing_since    = NULL,
         updated_at       = now()
   WHERE id_enterprise = p_ent;
END $$;
