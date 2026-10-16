-- Reversal: recreate the 1-line PERFORM-new() shims (identical to the P4-step2 originals).
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1hour() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_equipment_oee_hourly(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1day() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_equipment_oee_daily(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1week() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_equipment_oee_weekly(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_1month() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_equipment_oee_monthly(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_shift() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_equipment_oee_shift(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_shift_1week() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_equipment_oee_shift_weekly(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_equipment_runtime_shift_1month() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_equipment_oee_shift_monthly(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_area_runtime_1day() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_area_oee_daily(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_area_runtime_shift() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_area_oee_shift(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_site_runtime_1day() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_site_oee_daily(); END $$;
CREATE OR REPLACE FUNCTION public.piot_create_site_runtime_shift() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM public.piot_create_site_oee_shift(); END $$;
