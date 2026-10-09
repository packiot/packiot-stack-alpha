-- #224 P4 contract — drop the 11 transitional piot_create_*_runtime_* PERFORM-new()
-- shims. Prerequisite (proven live before applying): stream-engine provision.go
-- repointed to the canonical piot_create_*_oee_* procs (PR #1143, deployed) and
-- writer-audit clean (no DB-internal caller; stream-engine sole external caller now
-- on the new names). No-CASCADE drop success proves 0 remaining dependents.
DROP FUNCTION IF EXISTS public.piot_create_equipment_runtime_1hour();
DROP FUNCTION IF EXISTS public.piot_create_equipment_runtime_1day();
DROP FUNCTION IF EXISTS public.piot_create_equipment_runtime_1week();
DROP FUNCTION IF EXISTS public.piot_create_equipment_runtime_1month();
DROP FUNCTION IF EXISTS public.piot_create_equipment_runtime_shift();
DROP FUNCTION IF EXISTS public.piot_create_equipment_runtime_shift_1week();
DROP FUNCTION IF EXISTS public.piot_create_equipment_runtime_shift_1month();
DROP FUNCTION IF EXISTS public.piot_create_area_runtime_1day();
DROP FUNCTION IF EXISTS public.piot_create_area_runtime_shift();
DROP FUNCTION IF EXISTS public.piot_create_site_runtime_1day();
DROP FUNCTION IF EXISTS public.piot_create_site_runtime_shift();
