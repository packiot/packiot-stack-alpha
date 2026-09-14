-- Rollback for t285 — restore the 2 carrier tables + the original
-- RETURNS SETOF <table> shift/day functions (exact DDL captured pre-change).
-- Target DB: packiot_analytics (10.10.10.89)

CREATE TABLE public.h_piot_day_week_begin (
  id_enterprise integer,
  packml_topic character varying,
  day_begin integer,
  week_begin integer
);

CREATE TABLE public.h_shift_hours_per_equipment_packml_topic (
  id_enterprise integer,
  packml_topic character varying,
  shift_hours jsonb[]
);

DROP FUNCTION IF EXISTS public.piot_get_shift_hours_by_enterprise_packml_topic_2(character varying, integer);
DROP FUNCTION IF EXISTS public.piot_get_shift_hours_by_packml_topic_2(character varying);
DROP FUNCTION IF EXISTS public.piot_get_day_week_begin_by_packml_topic(character varying);

CREATE OR REPLACE FUNCTION public.piot_get_day_week_begin_by_packml_topic(in_topic character varying)
 RETURNS SETOF public.h_piot_day_week_begin
 LANGUAGE sql
 STABLE
AS $function$
    SELECT
        pr.id_enterprise,
        pr.packml_topic,
        COALESCE(a.day_begin, si.day_begin, e.day_begin, 0) AS day_begin,
        COALESCE(si.week_begin, e.week_begin, 0)            AS week_begin
    FROM packml_register pr
    JOIN enterprises e  ON e.id_enterprise = pr.id_enterprise
    LEFT JOIN sites  si ON si.id_site       = pr.id_site
    LEFT JOIN areas  a  ON a.id_area        = pr.id_area
    WHERE pr.packml_topic = in_topic;
$function$;

CREATE OR REPLACE FUNCTION public.piot_get_shift_hours_by_packml_topic_2(in_topic character varying)
 RETURNS SETOF public.h_shift_hours_per_equipment_packml_topic
 LANGUAGE sql
 STABLE
AS $function$
    SELECT
        id_enterprise, packml_topic, array_agg(sh_per_equip) AS shift_hours
    FROM (
        SELECT eq.id_enterprise, packml.packml_topic,
            jsonb_build_object(
                'id_shift_hour', sh.id_shift_hour,
                'id_shift',      sh.id_shift,
                'cd_shift',      sh.cd_shift,
                'begin_time',    sh.begin_time,
                'end_time',      sh.end_time,
                'id_site',       sh.id_site,
                'id_area',       sh.id_area,
                'day_number',    sh.day_number,
                'day_week',      sh.day_week,
                'shift_size',    sh.shift_size,
                'duration',      sh.duration
            ) AS sh_per_equip
        FROM (
            SELECT * FROM equipments
            WHERE id_enterprise = (
                SELECT id_enterprise FROM packml_register
                WHERE packml_topic = (string_to_array(in_topic, '/'))[1]
            )
        ) eq
        JOIN (
            SELECT *
            FROM packml_register
            WHERE
                CASE cardinality(string_to_array(in_topic, '/'))
                    WHEN 4 THEN id_equipment  = (SELECT id_equipment  FROM packml_register WHERE packml_topic = in_topic)
                    WHEN 3 THEN id_area       = (SELECT id_area       FROM packml_register WHERE packml_topic = in_topic)
                    WHEN 2 THEN id_site       = (SELECT id_site       FROM packml_register WHERE packml_topic = in_topic)
                    ELSE id_enterprise        = (SELECT id_enterprise FROM packml_register WHERE packml_topic = (string_to_array(in_topic, '/'))[1])
                END
                AND active = true
                AND id_equipment IS NOT NULL
                AND packml_topic LIKE '%/%/%/%'
                AND packml_topic NOT LIKE '%/%/%/%/%'
        ) packml ON packml.id_equipment = eq.id_equipment
        JOIN piot_get_shift_hours_by_equipment(eq.id_enterprise, eq.id_equipment) sh ON true
        GROUP BY eq.id_enterprise, eq.id_equipment, sh.id_shift_hour, sh.id_shift, sh.cd_shift,
                 sh.begin_time, sh.end_time, sh.id_site, sh.id_area, sh.day_number, sh.day_week,
                 sh.shift_size, sh.duration, packml.packml_topic
    ) eqs
    GROUP BY id_enterprise, packml_topic;
$function$;

CREATE OR REPLACE FUNCTION public.piot_get_shift_hours_by_enterprise_packml_topic_2(in_topic character varying, in_enterprise integer DEFAULT NULL::integer)
 RETURNS SETOF public.h_shift_hours_per_equipment_packml_topic
 LANGUAGE sql
 STABLE
AS $function$
    SELECT * FROM piot_get_shift_hours_by_packml_topic_2(in_topic);
$function$;
