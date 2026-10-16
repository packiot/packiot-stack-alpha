-- 14_p4_rename_provision_procs_oee.sql
-- P4 step 2 (procs): rename the 11 piot_create_*_runtime provisioning procs to
-- piot_create_*_oee_* (matching the renamed grain tables). EXPAND phase: each old
-- name is kept as a thin plpgsql shim (PERFORM new()) so the LIVE external caller
-- (stream-engine internal/rollup/provision.go provisionFns, hourly, fail-soft) is
-- unaffected. Procs are public-only (11, single set; no ev_* flow schemas).
-- CONTRACT (follow-up, needs deploy): update provisionFns to the new names +
-- edge-node-red/db/20-oee-engine-parity.sql bootstrap defs, deploy stream-engine,
-- verify runtime-provision runs on new names, then DROP the 11 shims (15b).
BEGIN;
ALTER FUNCTION public.piot_create_area_runtime_1day() RENAME TO piot_create_area_oee_daily;
ALTER FUNCTION public.piot_create_area_runtime_shift() RENAME TO piot_create_area_oee_shift;
ALTER FUNCTION public.piot_create_equipment_runtime_1day() RENAME TO piot_create_equipment_oee_daily;
ALTER FUNCTION public.piot_create_equipment_runtime_1hour() RENAME TO piot_create_equipment_oee_hourly;
ALTER FUNCTION public.piot_create_equipment_runtime_1month() RENAME TO piot_create_equipment_oee_monthly;
ALTER FUNCTION public.piot_create_equipment_runtime_1week() RENAME TO piot_create_equipment_oee_weekly;
ALTER FUNCTION public.piot_create_equipment_runtime_shift() RENAME TO piot_create_equipment_oee_shift;
ALTER FUNCTION public.piot_create_equipment_runtime_shift_1month() RENAME TO piot_create_equipment_oee_shift_monthly;
ALTER FUNCTION public.piot_create_equipment_runtime_shift_1week() RENAME TO piot_create_equipment_oee_shift_weekly;
ALTER FUNCTION public.piot_create_site_runtime_1day() RENAME TO piot_create_site_oee_daily;
ALTER FUNCTION public.piot_create_site_runtime_shift() RENAME TO piot_create_site_oee_shift;

CREATE OR REPLACE FUNCTION public.piot_create_area_runtime_1day() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_area_oee_daily(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_area_runtime_shift() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_area_oee_shift(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1day() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_equipment_oee_daily(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1hour() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_equipment_oee_hourly(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1month() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_equipment_oee_monthly(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1week() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_equipment_oee_weekly(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_shift() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_equipment_oee_shift(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_shift_1month() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_equipment_oee_shift_monthly(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_shift_1week() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_equipment_oee_shift_weekly(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_site_runtime_1day() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_site_oee_daily(); END $shim$;
CREATE OR REPLACE FUNCTION public.piot_create_site_runtime_shift() RETURNS void LANGUAGE plpgsql AS $shim$ BEGIN PERFORM public.piot_create_site_oee_shift(); END $shim$;
COMMIT;
