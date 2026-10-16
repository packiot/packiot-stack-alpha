-- Task #221 — drop the legacy public.h_piot_machine_speed (superseded by the
-- canonical serving.machine_speed, #221). Gated on ZERO live consumers:
--   * read-api dataset `machine-speed` repointed to serving.machine_speed + DEPLOYED
--     (staging read-api rebuilt, live HTTP 200 proof).
--   * pg_depend / view+matview scan: no DB object references it.
--   * repo grep: the only consumer was services/read-api datasets.go (repointed).
-- No CASCADE — a dependency would raise, not silently cascade. Reversible via
-- 02_drop_legacy_h_piot_machine_speed.down.sql (full original definition).
DROP FUNCTION IF EXISTS public.h_piot_machine_speed(integer,text,text,text,text,text,timestamptz,timestamptz,text,text);
