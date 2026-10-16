-- t284 step 2 — drop the 3 now-orphaned LIVE carrier tables.
-- Run AFTER 01-rewrite-fns.sql (which removes the functions' return-type
-- dependency on these tables). RESTRICT = fail loudly if any dep remains.
-- Target DB: packiot_analytics (10.10.10.89)

DROP TABLE public.h_machine_speed;
DROP TABLE public.h_piot_get_downtimes_per_category_equipment_level_new;
DROP TABLE public.h_downtimes_table_with_sector_2;
