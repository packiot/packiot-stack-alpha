#!/usr/bin/env bash
# PRODT-170 operator Events windows on a throwaway postgres:15 (no real database is touched). Usage:
#   bash run.sh          # fixture + the CURRENT functions (t-operator-events-dedupe, t-adr0061-p3a) + this migration
#   OLD=1 bash run.sh    # same WITHOUT this migration: proves the assertions fail on the old code
# Window starts are checked against an INDEPENDENT oracle (plain SQL over the fixture calendar), not against the
# helpers the migration calls. The site is America/Sao_Paulo with day_begin -3000 (day starts 23:10 local =
# 02:10 UTC), so the production day never starts at UTC midnight.
set -uo pipefail
cd "$(dirname "$0")/../.."   # db/migrations
NAME=p170test-$$
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=x postgres:15-alpine >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
until docker exec "$NAME" pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done; sleep 2
P() { docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$NAME" psql -U postgres -X -q -At -v ON_ERROR_STOP=1 "$@"; }
set -e
P -c "ALTER DATABASE postgres SET search_path = silver, serving, core, gold, public"
P < t-prodt170-operator-events-windows/test/fixture.sql >/dev/null
P < t-operator-events-dedupe/01-up.sql >/dev/null
P < t-adr0061-p3a-operator-by-id/01-up.sql >/dev/null
if [ "${OLD:-0}" = 1 ]; then echo "== OLD code (migration NOT applied) — failures expected"
else P < t-prodt170-operator-events-windows/01-up.sql >/dev/null; P < t-prodt170-operator-events-windows/01-up.sql >/dev/null
  echo "== migration applied (twice: idempotent)"; fi
set +e

P <<'SQL' >/dev/null
INSERT INTO core.enterprises (id_enterprise, nm_enterprise, active, timezone, day_begin, week_begin) VALUES (1, 'ACME', true, 'America/Sao_Paulo', -3000, -3000);
INSERT INTO core.sites (id_site, id_enterprise, nm_site, timezone, day_begin, week_begin) VALUES (1, 1, 'Plant', 'America/Sao_Paulo', -3000, -3000);
INSERT INTO core.areas (id_area, id_site, id_enterprise, nm_area, day_begin) VALUES (10, 1, 1, 'Packaging', -3000);
INSERT INTO core.equipments (id_equipment, id_enterprise, id_site, id_area, tp_equipment, nm_equipment, stop_threshold_time, active)
VALUES (100, 1, 1, 10, 3, 'Line 1', 60, true);
INSERT INTO core.packml_register (packml_topic, id_equipment, active, id_enterprise) VALUES ('acme/plant/pack/L1', 100, true, 1);
-- area calendar: three 8-hour shifts every day, from the operational week begin
INSERT INTO core.shift_hours (id_shift_hour, id_shift, id_enterprise, id_site, id_area, begin_time, end_time, shift_size)
SELECT k + 1, 1, 1, 1, 10, k * 28800, (k + 1) * 28800, 28800 FROM generate_series(0, 20) k;

-- ORACLE: window starts computed WITHOUT the DB helpers (D = production day, S = shift, M = UTC midnight)
CREATE TABLE public.oracle AS
WITH n AS (SELECT now() AS now, 'America/Sao_Paulo'::text AS tz),
     b AS (SELECT now, tz,
                  (date_trunc('day', (now AT TIME ZONE tz) + interval '3000 s') - interval '3000 s') AT TIME ZONE tz AS d,
                  (date_trunc('week', (now AT TIME ZONE tz) + interval '3000 s') AT TIME ZONE tz) - interval '3000 s' AS w,
                  date_trunc('day', now AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS m FROM n)
SELECT now, d, m, w + floor(extract(epoch FROM now - w) / 28800) * interval '28800 s' AS s FROM b;

CREATE FUNCTION public.ev(id int, ts timestamptz, te timestamptz, st int, cat text DEFAULT NULL) RETURNS void
LANGUAGE sql AS $$ INSERT INTO silver.equipment_events (id_equipment_event, id_equipment, id_enterprise, ts_event, ts_end, duration, status, cd_category)
  VALUES (id, 100, 1, ts, te, extract(epoch FROM te - ts)::int, st, cat) $$;
SELECT ev(1, d + interval '1 min', d + interval '11 min', 10) FROM oracle;           -- in the production day
SELECT ev(2, d - interval '1 min', d + interval '9 min', 10) FROM oracle;            -- started before it
-- UTC-midnight trap: between UTC midnight and the production-day start (or just before midnight if the day started
-- yesterday 02:10 UTC). A UTC-date implementation decides it the other way.
SELECT ev(3, CASE WHEN m < d THEN m + interval '30 min' ELSE m - interval '30 min' END,
             CASE WHEN m < d THEN m + interval '40 min' ELSE m - interval '20 min' END, 10) FROM oracle;
SELECT ev(4, now - interval '3 days', NULL, 10) FROM oracle;                          -- ONGOING, started long ago
SELECT ev(5, d + interval '3 min', d + interval '3 min 30 s', 10) FROM oracle;        -- shorter than the 60 s minimum
SELECT ev(6, d + interval '4 min', NULL, 6) FROM oracle;                              -- running, not a stop
SELECT ev(7, d + interval '5 min', d + interval '15 min', 20) FROM oracle;            -- NO DATA, not a stop
SELECT ev(8, now - interval '8 days', NULL, 10) FROM oracle;                          -- ongoing beyond the 7-day ceiling
SELECT ev(100 + i, d + interval '6 min' + i * interval '10 s', d + interval '8 min' + i * interval '10 s', 10)
  FROM oracle, generate_series(0, 38) i;                                              -- 39 stops: all reachable (AC-18)
SELECT ev(20, s + interval '1 min', s + interval '7 min', 11) FROM oracle;            -- in the current shift
SELECT ev(21, s - interval '2 min', s - interval '1 min 30 s' + interval '60 s', 11) FROM oracle; -- just before it
-- history (with a reason)
SELECT ev(40, now - interval '23 hours', now - interval '22 hours', 10, 'C1') FROM oracle;  -- started 23 h ago
SELECT ev(41, now - interval '25 hours', now - interval '1 hour', 10, 'C1') FROM oracle;    -- started 25 h ago, ended 1 h ago
INSERT INTO silver.equipment_events_man (id_equipment_event, id_equipment, id_enterprise, ts_event, ts_end, cd_category)
SELECT 42, 100, 1, now - interval '2 hours', now - interval '1 hour', 'M1' FROM oracle
UNION ALL SELECT 43, 100, 1, now - interval '30 hours', now - interval '29 hours', 'M1' FROM oracle;
INSERT INTO silver.equipment_events_low_speed (id_equipment_event, id_equipment, id_enterprise, ts_event, ts_end, duration, status,
  cd_category, cd_subcategory, desc_category, desc_subcategory)
SELECT 44, 100, 1, now - interval '1 hour', now - interval '50 min', 600, 1, 'C', 'S', 'DC', 'DS' FROM oracle;

-- the RN-17 pending rule over the fixture, given a window start (independent of the serving functions)
CREATE FUNCTION public.expected_pending(p_start timestamptz) RETURNS int[] LANGUAGE sql STABLE AS $$
  SELECT coalesce(array_agg(id_equipment_event::int ORDER BY ts_event DESC), '{}') FROM silver.equipment_events
   WHERE cd_category IS NULL AND status NOT IN (6, 20) AND (duration >= 60 OR duration IS NULL)
     AND (ts_event >= p_start OR ts_end IS NULL) AND ts_event >= now() - interval '7 days' $$;
CREATE FUNCTION public.expected_history(p_start timestamptz) RETURNS int[] LANGUAGE sql STABLE AS $$
  SELECT coalesce(array_agg(id ORDER BY ts DESC, id), '{}') FROM (
    SELECT id_equipment_event::int id, ts_event ts FROM silver.equipment_events WHERE cd_category IS NOT NULL AND ts_event >= p_start
    UNION ALL SELECT id_equipment_event::int, ts_event FROM silver.equipment_events_man WHERE ts_event >= p_start
    UNION ALL SELECT id_equipment_event::int, ts_event FROM silver.equipment_events_low_speed WHERE ts_event >= p_start) x $$;
CREATE FUNCTION public.pending_ids() RETURNS int[] LANGUAGE sql STABLE AS $$
  SELECT coalesce(array_agg(id_equipment_event::int ORDER BY ts_event DESC), '{}') FROM serving.pending_downtime('{acme/plant/pack/L1}') $$;
CREATE FUNCTION public.history_ids() RETURNS int[] LANGUAGE sql STABLE AS $$
  SELECT coalesce(array_agg(id_equipment_event::int ORDER BY ts_event DESC, id_equipment_event), '{}') FROM serving.events_timeline('{acme/plant/pack/L1}') $$;
SQL

FAILED=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got '$2' want '$3'"; FAILED=1; fi; }
q() { P -c "$1" 2>&1 | tail -1; }
has() { q "SELECT $1 = ANY(pending_ids())"; }

# T1 defaults (user decision): pending = current production day, history = last 24 hours
P -c "INSERT INTO core.enterprises (id_enterprise, nm_enterprise) VALUES (2, 'New client')" >/dev/null 2>&1
ok "T1 defaults for a new enterprise" "$(q "SELECT concat_ws(',', operator_pending_window, operator_pending_hours, operator_history_window, operator_history_hours) FROM core.enterprises WHERE id_enterprise = 2")" "production_day,24,hours,24"
# T2 production-day start = the site calendar, not the UTC date
ok "T2 oracle: production day does not start at UTC midnight" "$(q "SELECT d <> m AND d <> m - interval '1 day' FROM oracle")" "t"
ok "T2 pending window start = production-day start (02:10 UTC)" "$(q "SELECT pending_start = d FROM serving.operator_events_window_by_equipment('{100}'), oracle")" "t"
# T3 default pending list = exactly the RN-17 stops since the production-day start, plus ongoing ones
ok "T3 pending list = oracle(production day)" "$(q "SELECT pending_ids() = expected_pending(d) FROM oracle")" "t"
ok "T3 stop started 1 min before the production day is NOT pending" "$(has 2)" "f"
ok "T3 UTC-midnight trap decided by the production day" "$(q "SELECT (3 = ANY(pending_ids())) = (ts_event >= d) FROM silver.equipment_events, oracle WHERE id_equipment_event = 3")" "t"
ok "T3 ongoing stop started 3 days ago IS pending (AC-20)" "$(has 4)" "t"
ok "T3 short / running / no-data rows are not pending" "$(q "SELECT NOT (pending_ids() && '{5,6,7}')")" "t"
ok "T3 all 39 burst stops reachable (no row cap)" "$(q "SELECT count(*) FROM unnest(pending_ids()) i WHERE i BETWEEN 100 AND 138")" "39"
# T4 badge = list: the operator badge is the pending list's length; v1 (topics) and v2 (ids) agree with the oracle
ok "T4 badge count = v1 list = v2 list = oracle" "$(q "SELECT (SELECT count(*) FROM serving.pending_downtime('{acme/plant/pack/L1}')) || '=' || (SELECT count(*) FROM serving.pending_downtime_by_equipment('{100}')) || '=' || cardinality(expected_pending(d)) FROM oracle")" "$(q "SELECT c || '=' || c || '=' || c FROM (SELECT cardinality(expected_pending(d)) c FROM oracle) x")"
# T5 default history = stops with a reason that STARTED in the last 24 hours (old: ended in the last day)
ok "T5 history list = oracle(last 24 h)" "$(q "SELECT history_ids() = expected_history(now() - interval '24 hours')")" "t"
ok "T5 started 25 h ago (ended 1 h ago) is NOT in history" "$(q "SELECT 41 = ANY(history_ids())")" "f"
ok "T5 low-speed row keeps its columns (cd_subcategory)" "$(q "SELECT cd_subcategory || '/' || desc_category FROM serving.events_timeline('{acme/plant/pack/L1}') WHERE id_equipment_event = 44")" "S/DC"
# T6 current shift (AC-20): stops since the shift start, plus any ongoing stop that started earlier
P -c "UPDATE core.enterprises SET operator_pending_window = 'shift' WHERE id_enterprise = 1" >/dev/null 2>&1
ok "T6 shift window start = current shift start" "$(q "SELECT pending_start = s FROM serving.operator_events_window_by_equipment('{100}'), oracle")" "t"
ok "T6 pending list = oracle(shift)" "$(q "SELECT pending_ids() = expected_pending(s) FROM oracle")" "t"
ok "T6 stop just before the shift is NOT pending; ongoing older stop IS" "$(q "SELECT (21 = ANY(pending_ids())) || ',' || (4 = ANY(pending_ids())) || ',' || (20 = ANY(pending_ids()))")" "false,true,true"
# T7 last N hours (history = shift as well, to prove each list has its own window)
P -c "UPDATE core.enterprises SET operator_pending_window = 'hours', operator_pending_hours = 2, operator_history_window = 'shift' WHERE id_enterprise = 1" >/dev/null 2>&1
ok "T7 pending = last 2 h" "$(q "SELECT pending_ids() = expected_pending(now() - interval '2 hours')")" "t"
ok "T7 history = current shift" "$(q "SELECT history_ids() = expected_history(s) FROM oracle")" "t"
# T8 never longer than 7 days (AC-21 at the database: the CHECK refuses it; the function clamps)
ok "T8 169 hours refused" "$(P -c "UPDATE core.enterprises SET operator_pending_hours = 169 WHERE id_enterprise = 1" 2>&1 | grep -c 'violates check constraint')" "1"
ok "T8 unknown window kind refused" "$(P -c "UPDATE core.enterprises SET operator_history_window = 'week' WHERE id_enterprise = 1" 2>&1 | grep -c 'violates check constraint')" "1"
P -c "UPDATE core.enterprises SET operator_pending_window = 'hours', operator_pending_hours = 168 WHERE id_enterprise = 1" >/dev/null 2>&1
ok "T8 168 hours accepted = 7 days" "$(q "SELECT pending_start = now() - interval '7 days' FROM serving.operator_events_window_by_equipment('{100}')")" "t"
ok "T8 a longer request is clamped to 7 days" "$(q "SELECT serving.operator_window_start(100, 'hours', 1000, now()) = now() - interval '7 days'")" "t"
ok "T9 ongoing stop older than the 7-day ceiling is not listed (NFR-01 literal bound)" "$(has 8)" "f"
ok "T10 readapi_ro may execute the window read" "$(q "SELECT has_function_privilege('readapi_ro', 'serving.operator_events_window_by_equipment(integer[])', 'EXECUTE')")" "t"
ok "T10 reflector may update the new columns" "$(q "SELECT has_column_privilege('prod_reflector', 'core.enterprises', 'operator_pending_hours', 'UPDATE')")" "t"

[ "$FAILED" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
