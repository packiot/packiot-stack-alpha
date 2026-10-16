-- t285 step 2 — drop the 2 now-orphaned shift/day carrier tables.
-- Run AFTER 01-rewrite-fns.sql. RESTRICT = fail loudly if any dep remains.
-- Target DB: packiot_analytics (10.10.10.89)

DROP TABLE public.h_piot_day_week_begin;
DROP TABLE public.h_shift_hours_per_equipment_packml_topic;
