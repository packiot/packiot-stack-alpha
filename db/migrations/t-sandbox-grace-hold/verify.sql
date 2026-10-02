-- (inside one transaction now() is frozen at its start: fake changes are placed relative to it)
-- verify for t-sandbox-grace-hold — walks the hold state machine on the REAL data inside
-- the caller's transaction (run as: BEGIN; \i 01-up.sql; \i verify.sql; ROLLBACK;).
-- Every line prints label|value; the expected value is in the label.
\set ON_ERROR_STOP 1

-- start clean: last heal = now → nothing held
UPDATE ops.sandbox_state SET last_heal_at = now() - interval '1 hour', hold_until = NULL, healing_since = NULL, grace = interval '4 hours' WHERE id_enterprise = 2000003;
SELECT 'V1 fresh: held=f', held FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;

-- a READ does not hold
INSERT INTO identity.user_logs (ts_event, id_enterprise, category, ts_log) VALUES (now(), 2000003, 'shift-hours-listed', now() - interval '20 minutes');
SELECT 'V2 read only: held=f', held FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;

-- a CHANGE holds; not due for 4 h
INSERT INTO identity.user_logs (ts_event, id_enterprise, category, ts_log) VALUES (now(), 2000003, 'order-created-started', now() - interval '10 minutes');
SELECT 'V3 change: held=t due=f', held, heal_due, last_change FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;
SELECT 'V4 replicator sees held=t', ops.sandbox_held(2000003);
SELECT 'V5 ent 3 (unmanaged) held=f', ops.sandbox_held(3);

-- a non-forced heal refuses while held and not due
DO $$ BEGIN
  PERFORM ops.sandbox_heal_begin(2000003, false);
  RAISE EXCEPTION 'V6 FAIL: heal_begin did not refuse an active hold';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'V6 FAIL%' THEN RAISE; END IF;
  RAISE NOTICE 'V6 ok: refused (%)', left(SQLERRM, 60);
END $$;

-- manual extension beyond grace keeps it not-due
UPDATE ops.sandbox_state SET grace = interval '0', hold_until = now() + interval '1 hour' WHERE id_enterprise = 2000003;
SELECT 'V7 grace 0 + hold_until +1h: due=f', heal_due FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;

-- grace elapsed and no extension → due
UPDATE ops.sandbox_state SET hold_until = NULL WHERE id_enterprise = 2000003;
SELECT 'V8 grace elapsed: due=t', heal_due FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;

-- heal: begin (allowed when due) keeps the hold ON while healing
SELECT 'V9 begin ok', ops.sandbox_heal_begin(2000003, false) IS NOT NULL;
SELECT 'V10 healing: held=t due=f', held, heal_due FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;

-- end ok → released; the change before the heal no longer holds
SELECT 'V11 end', ops.sandbox_heal_end(2000003, true, 'verify');
SELECT 'V12 released: held=f', held, last_heal_status LIKE 'ok: verify%' FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;

-- a change AFTER the heal re-arms the hold
INSERT INTO identity.user_logs (ts_event, id_enterprise, category, ts_log) VALUES (now(), 2000003, 'event-justified', clock_timestamp() + interval '1 second');
SELECT 'V13 new change: held=t', held FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;

-- a heal that crashed (healing_since > 1 h old, change still pending) is due again
DELETE FROM identity.user_logs WHERE id_enterprise = 2000003 AND ts_log > now(); -- V13's synthetic change (stamped after the frozen now())
UPDATE ops.sandbox_state SET last_heal_at = now() - interval '30 minutes', healing_since = now() - interval '2 hours', grace = interval '0' WHERE id_enterprise = 2000003;
INSERT INTO identity.user_logs (ts_event, id_enterprise, category, ts_log) VALUES (now(), 2000003, 'area-edited', now() - interval '5 minutes');
SELECT 'V13b crashed heal: held=t due=t', held, heal_due FROM ops.sandbox_hold_status WHERE id_enterprise = 2000003;
UPDATE ops.sandbox_state SET healing_since = NULL WHERE id_enterprise = 2000003;

-- forced heal works while held
SELECT 'V14 forced begin ok', ops.sandbox_heal_begin(2000003, true) IS NOT NULL;
