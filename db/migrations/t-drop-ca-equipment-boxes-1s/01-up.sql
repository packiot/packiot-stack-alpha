-- t-drop-ca-equipment-boxes-1s — drop the dead 1-second box cagg and its refresh job (ADR-0063 Phase A1).
--
-- WHY (proved on staging 2026-10-14, read-only; evidence in the PR):
--   * silver.ca_equipment_boxes_1s holds 0 rows and its watermark is -infinity: its source rows
--     (silver.equipment_values with an analogs 'Label' key) are not written by the new stack
--     (0 of 1,064,220 rows in the last 2 days; no Go writer emits a 'Label' analog), and no
--     equipment is flagged custom->Label->has_labels (0 rows), so no reader could ever match.
--   * Its refresh policy (job 1014) still runs every 15 min for ~108 s (≈ 12 % of one vCPU):
--     40,109 stale 1-second invalidation ranges outside its 6 h window × 21,540 one-second batch
--     candidates in TimescaleDB's batch-split query (reproduced on 2.27.0: 42 s vs 7 ms).
--   * Readers: serving.report_shift and serving.report_shift_pre_p3b (labels_extract CTE) — the
--     only ones. pg_depend: no view depends on it. reports/sap13_body.sql:122 is inside a /* */
--     comment. The CTE is replaced by a typed empty stub; report_shift output is identical
--     (EXCEPT ALL both ways = 0 rows, enterprises 3 and 5, one snapshot) and ~2x faster.
--
-- WHAT: stub the two readers, remove both policies (refresh 1014, retention 1091), remove the
-- ops.retention_policy row (ops.apply_retention() would otherwise fail on the missing relation),
-- drop the cagg. Idempotent. rollback.sql recreates the cagg exactly (definition captured from the
-- live catalog) and restores both function bodies byte-for-byte.
--
-- APPLY: DROP MATERIALIZED VIEW on a cagg locks its raw hypertable (silver.equipment_values);
-- stop the stream-engine writers first (DBA guide rule), apply, start them again.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

-- 1. readers: replace the labels_extract CTE with a typed empty stub (same columns, 0 rows)
DO $mig$
DECLARE
  f    regprocedure;
  d    text;
  a    int;
  b    int;
  seg  text;
  stub constant text := $stub$),labels_extract as (-- t-drop-ca-equipment-boxes-1s: the 1-second box cagg was dropped; it never held a row on the new stack
select null::timestamptz as tz_value, null::integer as id_equipment, null::text as label_Job, null::double precision as label_amount
where false
$stub$;
BEGIN
  FOREACH f IN ARRAY ARRAY[to_regprocedure('serving.report_shift(integer,date,date)'),
                           to_regprocedure('serving.report_shift_pre_p3b(integer,date,date)')] LOOP
    CONTINUE WHEN f IS NULL;
    d := pg_get_functiondef(f);
    a := position('),labels_extract as (' in d);
    b := position('), negative_labels as (' in d);
    IF a = 0 OR b <= a THEN
      RAISE EXCEPTION '%: labels_extract CTE not found; body changed since this migration was written', f;
    END IF;
    seg := substr(d, a, b - a);
    IF seg = stub THEN
      RAISE NOTICE '%: labels_extract already stubbed', f;
      CONTINUE;
    END IF;
    IF position('ca_equipment_boxes_1s' in seg) = 0 THEN
      RAISE EXCEPTION '%: labels_extract does not read ca_equipment_boxes_1s; refusing to replace it', f;
    END IF;
    EXECUTE substr(d, 1, a - 1) || stub || substr(d, b);
    RAISE NOTICE '%: labels_extract stubbed', f;
  END LOOP;
END $mig$;

-- 2. policies, retention catalog row, the cagg
DO $mig$
BEGIN
  IF to_regclass('silver.ca_equipment_boxes_1s') IS NOT NULL THEN
    PERFORM remove_continuous_aggregate_policy('silver.ca_equipment_boxes_1s', if_exists => true);
    PERFORM remove_retention_policy('silver.ca_equipment_boxes_1s', if_exists => true);
  END IF;
END $mig$;
DELETE FROM ops.retention_policy WHERE relation = 'silver.ca_equipment_boxes_1s';
DROP MATERIALIZED VIEW IF EXISTS silver.ca_equipment_boxes_1s;

COMMIT;
