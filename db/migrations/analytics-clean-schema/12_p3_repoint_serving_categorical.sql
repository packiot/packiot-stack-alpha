-- P3 — repoint the 5 categorical serving fns off legacy ca_agg_equipment_values_1hour
-- onto the clean silver.equipment_categorical_1hour companion (Decision #1).
-- ============================================================================
-- Drift-proof, drop-in swap: for each fn, take the LIVE definition and change
-- ONLY the FROM target ca_agg_equipment_values_1hour -> silver.equipment_categorical_1hour.
-- Column names are identical (the companion exposes ca_agg's key + *_incr names),
-- so the body is otherwise byte-identical -> equivalent by construction (gated
-- symdiff at both data + fn level before this runs). CREATE OR REPLACE keeps the
-- existing serving.<fn>_row return types + signatures untouched.
-- Idempotent: re-running is a no-op if already repointed.
-- ============================================================================
DO $$
DECLARE
  fn text;
  def text;
  newdef text;
BEGIN
  FOREACH fn IN ARRAY ARRAY['oee_score_by_team','single_period_by_team','single_period_by_team_v4','targets','overview_production_chart']
  LOOP
    SELECT pg_get_functiondef(p.oid) INTO def
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='serving' AND p.proname=fn;
    IF def IS NULL THEN RAISE EXCEPTION 'serving.% not found', fn; END IF;
    newdef := replace(def, 'ca_agg_equipment_values_1hour', 'silver.equipment_categorical_1hour');
    IF newdef = def THEN
      RAISE NOTICE 'serving.% already repointed (no ca_agg ref)', fn;
    ELSE
      EXECUTE newdef;
      RAISE NOTICE 'repointed serving.% -> silver.equipment_categorical_1hour', fn;
    END IF;
  END LOOP;
END $$;

-- Post-condition: no serving fn may still reference the legacy categorical cagg.
DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace nsp ON nsp.oid=p.pronamespace
  WHERE nsp.nspname='serving' AND p.prokind='f'
    AND pg_get_functiondef(p.oid) LIKE '%ca_agg_equipment_values%';
  IF n <> 0 THEN RAISE EXCEPTION 'repoint incomplete: % serving fns still read ca_agg', n; END IF;
  RAISE NOTICE 'repoint verified: 0 serving fns read ca_agg_equipment_values';
END $$;
