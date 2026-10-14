-- repair-cpac-shadow-stale-open.sql — one-time close of the CPACK shadow deriver's stale open rows
-- (silver.equipment_events_cpac_shadow, enterprise 3). STAGING SHADOW TABLE ONLY: no client-facing
-- reader (no view, function, invariant or gold job reads it; only the ADR-0010 comparator does), and
-- never silver.equipment_events (ent 3 live / ent 5 live: 0 such rows there, checked 2026-10-14).
--
-- WHAT (staging, 2026-10-14): 11,942 rows open (ts_end NULL) and older than the deriver's 25 h window,
-- 49 equipments, 0 human-touched, all in the deriver's scope (status_type 0, tp 1/3).
--   11,853 from 2026-08-03 .. 09-29: the NULL-unsafe-guard era (#1486). The DO UPDATE never ran, so
--          every row inserted as the open tail stayed open after its successor appeared (gap to the
--          next row: p50 5 min, p90 70 min). 9,598 are stops followed by a run (10 → 6).
--       73 from 2026-09-29 .. 10-11: stops longer than the 25 h window; the RUNNING row came 1 to 13
--          days later, outside the window's reach. Fixed in code by #1772 (close pass); this closes the
--          ones that happened before it.
--       16 with NO successor: the machine is still stopped (or never produced again). LEFT OPEN.
-- SEMANTICS: an interval ends where the equipment's next transition begins (the deriver's own
-- lead(ts_event) rule, and closer.go's non-latest close). Deleting them would drop real stop starts.
--
-- SAFETY: literal bounds; only rows that are open, not human-touched and HAVE a successor; each
-- changed row is backed up first (whole row + the new end) in ops._bkp_cpac_shadow_open_20261014;
-- applied inside one transaction with a read-back that aborts on any mismatch. Plain table (not a
-- hypertable): no compressed-chunk DML trap. Runs in well under a second (27 k-row table).
--
-- RUN (staging DB host, as postgres; see docs/wiki/build/develop/add-a-migration.md step 8):
--   dry run (default; everything incl. the backup table is rolled back):
--     docker exec -i timescaledb psql -U postgres -d packiot_analytics -X < repair-cpac-shadow-stale-open.sql
--   apply:
--     docker exec -i timescaledb psql -U postgres -d packiot_analytics -X -v apply=1 < repair-cpac-shadow-stale-open.sql
-- UNDO (after an apply):
--   UPDATE silver.equipment_events_cpac_shadow ev SET ts_end = NULL, duration = b.duration
--     FROM ops._bkp_cpac_shadow_open_20261014 b
--    WHERE ev.id_equipment = b.id_equipment AND ev.ts_event = b.ts_event AND ev.ts_end = b.new_ts_end;
-- DROP the backup after 2026-11-14.
\set ON_ERROR_STOP 1
\if :{?apply}
\else
\set apply 0
\endif
BEGIN;
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

CREATE TABLE IF NOT EXISTS ops._bkp_cpac_shadow_open_20261014 (LIKE silver.equipment_events_cpac_shadow);
ALTER TABLE ops._bkp_cpac_shadow_open_20261014
    ADD COLUMN IF NOT EXISTS new_ts_end timestamptz,
    ADD COLUMN IF NOT EXISTS new_duration int,
    ADD COLUMN IF NOT EXISTS backed_up_at timestamptz DEFAULT now();
CREATE UNIQUE INDEX IF NOT EXISTS _bkp_cpac_shadow_open_20261014_key
    ON ops._bkp_cpac_shadow_open_20261014 (id_equipment, ts_event);
COMMENT ON TABLE ops._bkp_cpac_shadow_open_20261014 IS
    'Backup: CPACK shadow rows left open by the CPAC deriver, closed at their successor by scripts/ops/repair-cpac-shadow-stale-open.sql (2026-10-14). Whole original row + new_ts_end/new_duration; undo statement in the script header. DROP after 2026-11-14.';

-- candidates: open, not human-touched, with a successor, ts_event in a LITERAL range that is entirely
-- before the deriver's 25 h window at any apply time from now on (the deriver never rewrites them)
CREATE TEMP TABLE cand ON COMMIT DROP AS
WITH w AS (
    SELECT ev.id_equipment, ev.ts_event, ev.ts_end, ev.status,
           (ev.forced_creation_system IS TRUE
                OR ev.cd_category IS NOT NULL OR ev.cd_subcategory IS NOT NULL
                OR ev.cd_machine IS NOT NULL OR ev.txt_downtime_notes IS NOT NULL
                OR ev.planned_downtime IS TRUE OR ev.change_over IS TRUE OR ev.idle IS NOT NULL) AS human,
           lead(ev.ts_event) OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_event) AS ts_next,
           lead(ev.status)   OVER (PARTITION BY ev.id_equipment ORDER BY ev.ts_event) AS next_status
      FROM silver.equipment_events_cpac_shadow ev
     WHERE ev.id_enterprise = 3
)
SELECT id_equipment, ts_event, status, next_status, ts_next,
       extract(epoch FROM (ts_next - ts_event))::int AS new_duration
  FROM w
 WHERE ts_end IS NULL AND NOT human AND ts_next IS NOT NULL
   AND ts_event >= '2026-08-01 00:00:00+00' AND ts_event < '2026-10-13 00:00:00+00';
CREATE UNIQUE INDEX ON cand (id_equipment, ts_event);
ANALYZE cand;

\echo == plan: rows to close by status -> next status
SELECT status, next_status, count(*), min(ts_event), max(ts_event) FROM cand GROUP BY 1, 2 ORDER BY 3 DESC;

INSERT INTO ops._bkp_cpac_shadow_open_20261014
SELECT ev.*, c.ts_next, c.new_duration, now()
  FROM silver.equipment_events_cpac_shadow ev JOIN cand c USING (id_equipment, ts_event)
ON CONFLICT (id_equipment, ts_event) DO NOTHING;

UPDATE silver.equipment_events_cpac_shadow ev
   SET ts_end = c.ts_next, duration = c.new_duration
  FROM cand c
 WHERE ev.id_equipment = c.id_equipment AND ev.ts_event = c.ts_event
   AND ev.id_enterprise = 3 AND ev.ts_end IS NULL;

-- read-back: every candidate now ends at its successor, and is backed up; else abort
DO $$
DECLARE n_cand int; n_ok int; n_bkp int;
BEGIN
  SELECT count(*) INTO n_cand FROM cand;
  SELECT count(*) INTO n_ok FROM cand c JOIN silver.equipment_events_cpac_shadow ev USING (id_equipment, ts_event)
   WHERE ev.ts_end = c.ts_next AND ev.duration = c.new_duration;
  SELECT count(*) INTO n_bkp FROM cand c JOIN ops._bkp_cpac_shadow_open_20261014 b USING (id_equipment, ts_event)
   WHERE b.ts_end IS NULL AND b.new_ts_end = c.ts_next;
  RAISE NOTICE 'candidates %, read back closed %, backed up %', n_cand, n_ok, n_bkp;
  IF n_ok <> n_cand OR n_bkp <> n_cand THEN
    RAISE EXCEPTION 'read-back mismatch: candidates %, closed %, backed up %', n_cand, n_ok, n_bkp;
  END IF;
END $$;

\echo == left open, older than 25 h (expected: the no-successor rows + anything newer than the literal bound)
SELECT count(*) AS open_older_25h,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM silver.equipment_events_cpac_shadow n
                                           WHERE n.id_equipment = ev.id_equipment AND n.ts_event > ev.ts_event)) AS no_successor
  FROM silver.equipment_events_cpac_shadow ev
 WHERE ev.id_enterprise = 3 AND ev.ts_end IS NULL AND ev.ts_event < now() - interval '25 hours';

\if :apply
COMMIT;
\echo == APPLIED
\else
ROLLBACK;
\echo == DRY RUN: rolled back (re-run with -v apply=1 to apply)
\endif
