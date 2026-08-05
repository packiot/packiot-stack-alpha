-- 11-shift-hours-nullsafe-unique.sql — close the shift_hours duplicate loophole.
-- __SCH__ = target schema (public on packiot_shadow / F3). Idempotent.
--
-- CONTEXT. `shift_hours` shipped with UNIQUE (begin_time, end_time, id_site,
-- id_area, id_equipment). But every seeded/CS-Admin row has id_equipment = NULL,
-- and Postgres treats NULL <> NULL in a UNIQUE constraint — so that constraint
-- never fired for the (overwhelming) NULL-equipment case. A non-idempotent
-- topology seed re-ran ~4x and stacked 4 identical rows per (shift, weekday);
-- CPACK's weekly schedule showed "28 days" instead of 7 (data deduped 420->105).
--
-- This adds a NULL-SAFE unique index (PG15+ `NULLS NOT DISTINCT`) over the same
-- columns, so NULL id_equipment rows are compared as equal and a duplicate slot
-- is rejected at write time (fail-closed) — for the seed path AND the CS-Admin
-- save path. The legacy `shift_hours_un` constraint is left in place (harmless;
-- strictly subsumed). Verified zero existing violations before adding (prod).

BEGIN;

DO $$
BEGIN
  IF to_regclass('__SCH__.shift_hours') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'uq_shift_hours_slot_nullsafe') THEN
    EXECUTE 'CREATE UNIQUE INDEX uq_shift_hours_slot_nullsafe '
         || 'ON __SCH__.shift_hours (begin_time, end_time, id_site, id_area, id_equipment) '
         || 'NULLS NOT DISTINCT';
  END IF;
END $$;

COMMIT;
