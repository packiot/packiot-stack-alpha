-- t-analytics-history-backfill — tooling for T1 of
-- docs/plans/unified-hot-cold-serving-grain-tiered-retention.md
--
-- ops.bf_merge(stage, target, skip) — merge a STAGED backfill table into a live
-- target, NEVER overwriting what the pipeline computed:
--   * columns = intersection of stage ∩ target by name, minus `skip` (e.g. a
--     sequence-backed surrogate id, so the target's DEFAULT applies);
--   * every staged column is CAST to the target column's exact type (DuckDB stages
--     ranges as varchar, ints as bigint, …);
--   * INSERT … ON CONFLICT DO NOTHING — respects PKs AND exclusion constraints
--     (e.g. gold.production_orders_runtime's no-overlap EXCLUDE), so a row the
--     pipeline already owns always wins;
--   * PLUS a NOT EXISTS guard on the LOGICAL key `p_key` (IS NOT DISTINCT FROM, so NULLs
--     match) — required for tables with NO PK (gold.equipment_oee_shift_weekly/_monthly),
--     where ON CONFLICT alone would re-insert duplicates on a re-run.
-- Returns rows actually inserted (the AFTER-count truth — "insert ok" ≠ rows changed).
-- Idempotent: re-running a merge inserts 0.

CREATE SCHEMA IF NOT EXISTS ops;

DROP FUNCTION IF EXISTS ops.bf_merge(regclass, regclass, text[]);
CREATE OR REPLACE FUNCTION ops.bf_merge(p_stage regclass, p_target regclass, p_skip text[] DEFAULT '{}', p_key text[] DEFAULT '{}')
RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE cols text; casts text; n bigint; guard text := '';
BEGIN
  SELECT string_agg(format('%I', t.attname), ', ' ORDER BY t.attnum),
         string_agg(format('s.%I::%s', t.attname, format_type(t.atttypid, t.atttypmod)), ', ' ORDER BY t.attnum)
    INTO cols, casts
    FROM pg_attribute t
    JOIN pg_attribute s ON s.attrelid = p_stage AND s.attname = t.attname AND s.attnum > 0 AND NOT s.attisdropped
   WHERE t.attrelid = p_target AND t.attnum > 0 AND NOT t.attisdropped
     AND NOT (t.attname = ANY (p_skip));
  IF cols IS NULL THEN
    RAISE EXCEPTION 'bf_merge: no common columns between % and %', p_stage, p_target;
  END IF;
  IF cardinality(p_key) > 0 THEN
    -- '=' on NOT NULL key columns (B-tree indexable → index probe per row); IS NOT
    -- DISTINCT FROM only on nullable ones. (IS NOT DISTINCT FROM everywhere is not
    -- indexable → per-row seq scan of the target = O(n*m); a 322k-row merge ran >13 min.)
    SELECT string_agg(format(CASE WHEN a.attnotnull THEN 't.%1$I = s.%1$I::%2$s'
                                  ELSE 't.%1$I IS NOT DISTINCT FROM s.%1$I::%2$s' END,
                             k, format_type(a.atttypid, a.atttypmod)), ' AND ')
      INTO guard FROM unnest(p_key) k JOIN pg_attribute a ON a.attrelid = p_target AND a.attname = k;
    guard := format(' WHERE NOT EXISTS (SELECT 1 FROM %s t WHERE %s)', p_target, guard);
  END IF;
  -- No key ⇒ NO guard clause at all (an earlier 'WHERE NOT EXISTS (… WHERE true)' default
  -- was false for any non-empty target and silently inserted 0 — caught by a dry run).
  EXECUTE format('INSERT INTO %s (%s) SELECT %s FROM %s s%s ON CONFLICT DO NOTHING',
                 p_target, cols, casts, p_stage, guard);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

COMMENT ON FUNCTION ops.bf_merge(regclass, regclass, text[], text[]) IS
  'Merge a staged backfill table into a target: common columns, cast to target types, ON CONFLICT DO NOTHING. Returns inserted row count.';
