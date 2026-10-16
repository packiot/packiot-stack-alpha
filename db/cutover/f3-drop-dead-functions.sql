-- ─────────────────────────────────────────────────────────────────────────────
-- F3 CUTOVER FIX 4 (LOW): drop dead, permanently-erroring h_piot_* functions
--
-- Three legacy non-`_uns` mission-control / home functions error on EVERY call
-- and are not part of the read-api (refdata-api) contract, which uses only the
-- `_uns` variants (h_piot_home_uns, h_piot_get_mission_control_uns_3,
-- h_piot_get_mission_control_area_uns_2, h_piot_get_mission_control_timeline):
--
--   * h_piot_home(integer)
--       → ERROR: relation "ca_agg_equipment_values_1s" does not exist
--   * h_piot_get_mission_control(integer, text, text, text)
--       → dead legacy signature (array/type-literal mismatch on the text args)
--   * h_piot_get_mission_control_area(integer, text, text, text)
--       → same dead family; its BODY calls h_piot_get_mission_control, so it is a
--         dead dependent — dropping the base alone would leave it calling a
--         missing function. Dropped together.
--
-- Verified before applying: read-api's dataset registry (datasets.go) never
-- references any of the three; no other DB function/view references them
-- internally (pg_get_functiondef scan, prokind='f'); each errors when invoked.
--
-- Idempotent (DROP ... IF EXISTS with explicit signatures). MANIFEST.f3-target
-- is updated in the same PR to keep the parity gate green (init/snapshot still
-- CREATE them; this cutover DROP runs after init, so the end state has them gone).
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.h_piot_get_mission_control_area(integer, text, text, text);
DROP FUNCTION IF EXISTS public.h_piot_get_mission_control(integer, text, text, text);
DROP FUNCTION IF EXISTS public.h_piot_home(integer);
