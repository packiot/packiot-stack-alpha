-- widen-rollup-bigint.sql — REFACTORED schemas only (F2 shadow_go_port in
-- packiot, F3 public in packiot_shadow). NEVER legacy packiot.public.
--
-- The week/month runtime + UNS rollups SUM daily int4 aggregate columns. A
-- shadow compute-parity divergence for eq=51 (CPACK-Staging L8, a line)
-- produces a physically-impossible running_time (~707M/day vs legacy's 80160),
-- so the weekly/monthly sum overflows int4 and fails the ENTIRE rollup UPDATE —
-- a denial (SQLSTATE 22003) that blocks every equipment's rollup, in BOTH the
-- runtime grains AND the UNS grains. Widening the aggregate-grain int columns
-- to bigint stops the denial; the bake still flags eq=51's divergence (bigint
-- stores the wrong value, legacy stays int4 ⇒ mismatch surfaces, correctly).
--
-- Dynamic sweep over aggregate grains only (*_runtime_1week/1month +
-- uns_*_current_week/month), excluding id/flag columns. Idempotent.
-- Pass the target schema by sed-replacing __SCH__. Run once per refactored schema.

DO $$
DECLARE
    v_sch text := '__SCH__';
    r record;
BEGIN
    FOR r IN
        SELECT table_name, column_name
          FROM information_schema.columns
         WHERE table_schema = v_sch
           AND data_type = 'integer'
           AND column_name NOT LIKE 'id\_%'
           AND column_name NOT IN ('id','tp_equipment','status','status_type',
                                   'sequence_position','day_number','week_size')
           AND ( table_name ~ '_runtime_1(week|month)$'
              OR table_name ~ '^uns_.*_current_(week|month)$' )
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE bigint',
                       v_sch, r.table_name, r.column_name);
        RAISE NOTICE 'widened %.%.% -> bigint', v_sch, r.table_name, r.column_name;
    END LOOP;
END $$;
