-- ============================================================================
-- t244c :: Piece A — inline SAP report into serving.sap_report_data_sync
-- Makes the fn self-contained: inlines customer_reports.equipment_boxes_cust_13
-- (both the Branch-A labels_data ref AND the inlined _deb branch's ref) to
-- customer_reports.boxes (customer_id + label_key fenced), and inlines the
-- 27KB view customer_reports.v_sap_report_data_sync_customer_13_deb as a
-- parameterized subquery (id_enterprise=13 -> p_id_enterprise; id_site=29 ->
-- serving.report_sites(_, 'sap_sync_deb'); Europe/Zurich -> serving.report_tz(
-- _, 'sap_sync_deb')). Preserves the EXACT 19-column German output contract.
-- ADDITIVE: pure CREATE OR REPLACE (signature unchanged). Legacy drops are in 04.
-- ============================================================================
SET client_min_messages = warning;

-- Seed the sap_sync_deb profile (site 29 / Europe/Zurich) + label_key for ent 13.
-- Additive jsonb merge; other descriptor keys untouched. label_key also defaults
-- to 'Label_Neopac' in-body via COALESCE, so this seed is belt-and-suspenders.
UPDATE core.client_descriptors
   SET descriptor = jsonb_set(
         jsonb_set(coalesce(descriptor,'{}'::jsonb),
                   '{reports,sap_sync_deb}',
                   '{"timezone":"Europe/Zurich","site_scope":[29]}'::jsonb, true),
         '{reports,label_key}', '"Label_Neopac"'::jsonb, true),
       updated_at = now()
 WHERE id_enterprise = 13;

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION serving.sap_report_data_sync(p_id_enterprise integer)
RETURNS TABLE(linie character varying, tag date, shicht character varying, shicht_nummer integer,
    auftrag bigint, sum_labels double precision, rumpfe double precision, gutmenge double precision,
    rustzeit numeric, produktionszeit numeric, geplante_ausfallzeit numeric, ungeplante_ausfallzeit numeric,
    matfehler_ausfallzeit numeric, no_order numeric, auftrag_startzeit timestamp without time zone,
    running_h numeric, shift_start_time timestamp with time zone, data_type text, id_order_label text)
LANGUAGE sql STABLE AS $function$
WITH dias AS (
         SELECT generate_series(timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), now())::date - '4 days'::interval, timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN ers.ts_end > now() THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_oee_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.tp_equipment = 3 AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')))) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN eq.tp_equipment = 3 THEN e.id_parentequipment
                    WHEN eq.tp_equipment = 2 THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE e.id_parentequipment = eq.id_equipment AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE e.id_equipment_line = eq.id_equipment
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = p_id_enterprise AND equipments_1.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM agg_equipment_values_1min,
            start_counting_day scd
          WHERE (agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval) AND agg_equipment_values_1min.ts_value >= scd.start_day AND agg_equipment_values_1min.id_enterprise = p_id_enterprise AND agg_equipment_values_1min.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync'))
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.tp_equipment = 3 AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')))) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = p_id_enterprise AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN po_sequence_basis.id_order = po_sequence_basis.id_order_sec THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST(upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval, lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), now()::timestamp without time zone::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM turnos shi
             LEFT JOIN prod_orders po ON po.job_start < shi.tz_end AND po.job_end >= shi.tz_value AND po.id_equipment = shi.id_equipment
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM base_for_splits bfs
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value < bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = p_id_enterprise AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync'))))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = ANY (ARRAY[2, 9]) THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= COALESCE(e.stop_threshold_time, 0)::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < COALESCE(e.stop_threshold_time::double precision, 'Infinity'::double precision) THEN 5
                    WHEN dc."position" = 7 THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = p_id_enterprise AND e.tp_equipment = 3 AND e.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync'))
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '4 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE COALESCE(sb.nextts, now()) >= (( SELECT start_counting_day.start_day - '1 day'::interval
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM stops_raw st
             LEFT JOIN base_for_splits bfs ON tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim) AND bfs.id_equipment = st.id_equipment
          ORDER BY st.id_equipment, (GREATEST(st.tz_event, bfs.inicio)), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 0 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 1 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 2 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 3 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 4 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 5 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN st.downtimereason = 6 THEN date_part('epoch'::text, st.tz_end - st.tz_event)
                    ELSE NULL::double precision
                END), 0::double precision) AS dt_6
           FROM base_for_splits stpf
             LEFT JOIN split_bfs st ON st.tz_event < stpf.fim AND st.tz_end > stpf.inicio AND stpf.id_equipment = st.id_equipment
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM stops_final f
             LEFT JOIN press_quantity pqty ON f.id_equipment = pqty.id_equipment AND f.cd_shift::text = pqty.cd_shift::text AND f.ts_value_production = pqty.ts_value_production AND f.id_order = pqty.id_order AND f.inicio = pqty.inicio AND f.fim = pqty.fim AND f.id_shift = pqty.id_shift AND f.turno_hrs = pqty.turno_hrs
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN sum(l.label_amount) IS NULL THEN 0::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM base_for_splits bfs
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value < (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            date_part('epoch'::text, f.fim - f.inicio)::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             LEFT JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND f.id_order = pack.label_job::bigint
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            pack.label_job::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM final_and_press f
             JOIN packed_quantity pack ON f.inicio = pack.inicio AND f.fim = pack.fim AND f.id_equipment = pack.id_equipment AND pack.net_label IS NOT NULL AND pack.net_label <> 0::double precision AND f.id_order <> pack.label_job::bigint
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            ppf.shift_duration::double precision AS shift_duration,
            (ppf.shift_duration::double precision / 3600::double precision)::numeric(10,2) AS shift_duration_s,
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_6)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_4) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_6 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count::double precision, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor::double precision, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = p_id_enterprise AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = p_id_enterprise
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM customer_reports.boxes ebc
          WHERE ebc.customer_id = p_id_enterprise
            AND ebc.label_key = COALESCE(serving.report_config(p_id_enterprise) ->> 'label_key', 'Label_Neopac')
            AND (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = p_id_enterprise AND equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync')) AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '4 days'::interval)
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM turnos t
             LEFT JOIN labels_data ld ON t.id_equipment = ld.id_equipment AND ld.ts_value >= t.tz_value AND ld.ts_value < t.tz_end
             LEFT JOIN equipments eq ON eq.id_equipment = t.id_equipment
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM final_jobs fj
             LEFT JOIN final_labels fl ON fl.cd_equipment::text = fj.linie::text AND fl.id_order::integer = fj.auftrag AND fl.ts_value_production = fj.tag AND fl.cd_shift::text = fj.shicht::text
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM final_labels fl
             LEFT JOIN final1 f1 ON fl.cd_equipment::text = f1.linie::text AND fl.id_order::integer = f1.auftrag AND fl.ts_value_production = f1.tag AND fl.cd_shift::text = f1.shicht::text
          WHERE fl.sum_labels IS NOT NULL AND f1.id_order IS NULL
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN missing_jobs_labels.cd_shift::text = 'Frühschicht'::text THEN 1
                    WHEN missing_jobs_labels.cd_shift::text = 'Spätschicht'::text THEN 2
                    WHEN missing_jobs_labels.cd_shift::text = 'Nachtschicht'::text THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, (COALESCE(final10.auftrag, 0::bigint))) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, 0::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE final10.tag >= (timezone(serving.report_tz(p_id_enterprise, 'sap_sync'), now()) - '3 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11
UNION ALL
 SELECT deb_branch.linie,
    deb_branch.tag,
    deb_branch.shicht,
    deb_branch.shicht_nummer,
    deb_branch.auftrag,
    deb_branch.sum_labels,
    deb_branch.rumpfe,
    deb_branch.gutmenge,
    deb_branch.rustzeit,
    deb_branch.produktionszeit,
    deb_branch.geplante_ausfallzeit,
    deb_branch.ungeplante_ausfallzeit,
    deb_branch.matfehler_ausfallzeit,
    deb_branch.no_order,
    deb_branch.auftrag_startzeit,
    deb_branch.running_h,
    deb_branch.shift_start_time,
    deb_branch.data_type,
    deb_branch.id_order_label
   FROM (
 WITH dias AS (
         SELECT (generate_series(((timezone(serving.report_tz(p_id_enterprise, 'sap_sync_deb'), now()))::date - '4 days'::interval), ((timezone(serving.report_tz(p_id_enterprise, 'sap_sync_deb'), now()))::date)::timestamp without time zone, '1 day'::interval))::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(((timezone(serving.report_tz(p_id_enterprise, 'sap_sync_deb'), ers.ts_value))::time without time zone)::interval, 'HH24:MI'::text), '-', to_char(((timezone(serving.report_tz(p_id_enterprise, 'sap_sync_deb'), ers.ts_end))::time without time zone)::interval, 'HH24:MI'::text)) AS turno_hrs,
            ers.ts_value AS shift_start_time,
            ers.id_equipment,
            shi.cd_shift,
            ers.id_shift,
            ers.ts_value_production,
            ers.ts_value AS tz_value,
                CASE
                    WHEN (ers.ts_end > now()) THEN now()
                    ELSE ers.ts_end
                END AS tz_end
           FROM equipment_oee_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE ((ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = p_id_enterprise) AND (equipments.tp_equipment = 3) AND (equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb')))))) AND (ers.ts_value_production >= scd.start_day) AND (ers.ts_value <= now()) AND (shi.id_shift = ers.id_shift))
          ORDER BY ers.id_equipment, ers.ts_value
        ), equipamentos AS (
         SELECT e.id_equipment,
                CASE
                    WHEN (eq.tp_equipment = 3) THEN e.id_parentequipment
                    WHEN (eq.tp_equipment = 2) THEN eq.id_parentequipment
                    ELSE NULL::integer
                END AS id_equipment_line
           FROM equipments e,
            equipments eq
          WHERE ((e.id_parentequipment = eq.id_equipment) AND (e.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = p_id_enterprise) AND (equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))))
        ), linhas AS (
         SELECT e.id_equipment,
            eq.cd_equipment,
            e.id_equipment_line,
            eq.stop_threshold_time
           FROM equipamentos e,
            equipments eq
          WHERE (e.id_equipment_line = eq.id_equipment)
        UNION ALL
         SELECT equipments.id_equipment,
            equipments.cd_equipment,
            equipments.id_equipment AS id_equipment_line,
            equipments.stop_threshold_time
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = p_id_enterprise) AND (equipments_1.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))) AND (equipments_1.tp_equipment = 3))))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min.id_equipment,
            agg_equipment_values_1min.id_site,
            agg_equipment_values_1min.id_area,
            agg_equipment_values_1min.ts_value AS tz_value,
            agg_equipment_values_1min.gross_production_incr,
            agg_equipment_values_1min.net_production_incr
           FROM agg_equipment_values_1min,
            start_counting_day scd
          WHERE ((agg_equipment_values_1min.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = p_id_enterprise) AND (equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))) AND (equipments.tp_equipment = 3)))) AND (agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval)) AND (agg_equipment_values_1min.ts_value >= scd.start_day) AND (agg_equipment_values_1min.id_enterprise = p_id_enterprise) AND (agg_equipment_values_1min.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))))
        ), prod_orders AS (
         SELECT porun.id_equipment,
            po.id_enterprise,
            po.id_area,
            po.id_site,
            po.id_order,
            porun.runtime_timerange,
            lower(porun.runtime_timerange) AS job_start,
                CASE
                    WHEN (upper(porun.runtime_timerange) IS NULL) THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE ((porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = p_id_enterprise) AND (equipments.tp_equipment = 3) AND (equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb')))))) AND (po.id_equipment = porun.id_equipment) AND (po.id_enterprise = p_id_enterprise) AND (po.id_production_order = porun.id_production_order) AND (lower(porun.runtime_timerange) >= (now() - '90 days'::interval)))
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), labels AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
        ), po_sequence_basis AS (
         SELECT prod_orders.id_order,
            lead(prod_orders.id_order) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS id_order_sec,
            prod_orders.runtime_timerange,
            lead(prod_orders.runtime_timerange) OVER (ORDER BY prod_orders.id_order, prod_orders.runtime_timerange) AS runtime_timerange_sec
           FROM prod_orders
          ORDER BY prod_orders.id_order
        ), po_sequence AS (
         SELECT po_sequence_basis.id_order,
                CASE
                    WHEN (po_sequence_basis.id_order = po_sequence_basis.id_order_sec) THEN tstzrange(lower(po_sequence_basis.runtime_timerange), LEAST((upper(po_sequence_basis.runtime_timerange) + '06:00:00'::interval), lower(po_sequence_basis.runtime_timerange_sec)))
                    ELSE tstzrange(lower(po_sequence_basis.runtime_timerange), ((now())::timestamp without time zone)::timestamp with time zone)
                END AS runtime_timerange_new
           FROM po_sequence_basis
          ORDER BY po_sequence_basis.id_order, po_sequence_basis.runtime_timerange
        ), base_for_splits AS (
         SELECT shi.turno_hrs,
            shi.shift_start_time,
            shi.id_equipment,
            shi.cd_shift,
            shi.ts_value_production,
            po.id_order,
                CASE
                    WHEN (shi.tz_value > COALESCE(po.job_start, '2024-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_value
                    ELSE po.job_start
                END AS inicio,
                CASE
                    WHEN (shi.tz_end < COALESCE(po.job_end, '2100-01-01 06:00:00+00'::timestamp with time zone)) THEN shi.tz_end
                    ELSE po.job_end
                END AS fim,
            po.id_site,
            po.id_area,
            shi.id_shift
           FROM (turnos shi
             LEFT JOIN prod_orders po ON (((po.job_start < shi.tz_end) AND (po.job_end >= shi.tz_value) AND (po.id_equipment = shi.id_equipment))))
          ORDER BY shi.id_equipment, shi.tz_value
        ), press_quantity AS (
         SELECT bfs.id_equipment,
            bfs.cd_shift,
            bfs.ts_value_production,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
            sum(pc.gross_production_incr) AS gross,
            bfs.id_shift,
            bfs.turno_hrs,
            bfs.shift_start_time,
            sum(pc.net_production_incr) AS net
           FROM (base_for_splits bfs
             LEFT JOIN presscount pc ON (((pc.tz_value >= bfs.inicio) AND (pc.tz_value < bfs.fim) AND (pc.id_equipment = bfs.id_equipment) AND (pc.id_site = bfs.id_site) AND (pc.id_area = bfs.id_area))))
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = p_id_enterprise) AND (equipments_1.tp_equipment = 3) AND (equipments_1.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))))))
        ), category_level AS (
         SELECT top_level.id_equipment,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text) AS description,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) ->> 'code'::text))::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description
           FROM category_level
          ORDER BY category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN (dc."position" = 24) THEN 1
                    WHEN (dc."position" = ANY (ARRAY[2, 9])) THEN 2
                    WHEN (dc."position" = ANY (ARRAY[5, 8])) THEN 3
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) >= (COALESCE(e.stop_threshold_time, 0))::double precision)) THEN 4
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) < COALESCE((e.stop_threshold_time)::double precision, 'Infinity'::double precision))) THEN 5
                    WHEN (dc."position" = 7) THEN 6
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM ((equipment_events ee
             LEFT JOIN equipments e ON (((ee.id_equipment = e.id_equipment) AND (e.id_enterprise = p_id_enterprise) AND (e.tp_equipment = 3) AND (e.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))))))
             LEFT JOIN downtime_codes dc ON (((ee.cd_category)::text = dc.description)))
          WHERE ((ee.status = 10) AND (ee.ts_event >= (now() - '90 days'::interval)) AND (tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange((now() - '4 days'::interval), now())) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = p_id_enterprise) AND (equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))) AND (equipments.tp_equipment = 3)))))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_raw AS (
         SELECT sb.id_equipment,
            sb.ts_event AS tz_event,
            sb.nextts AS tz_end,
            sb.planned_downtime,
            sb.cd_category,
            sb.code,
            sb.downtimereason
           FROM stops_neopac_ch sb
          WHERE (COALESCE(sb.nextts, now()) >= ( SELECT (start_counting_day.start_day - '1 day'::interval)
                   FROM start_counting_day))
          ORDER BY sb.cd_equipment, sb.ts_event
        ), split_bfs AS (
         SELECT st.id_equipment,
            GREATEST(st.tz_event, bfs.inicio) AS tz_event,
            LEAST(COALESCE(st.tz_end, now()), bfs.fim) AS tz_end,
            st.planned_downtime,
            bfs.inicio,
            st.cd_category,
            st.code,
            st.downtimereason
           FROM (stops_raw st
             LEFT JOIN base_for_splits bfs ON (((tstzrange(st.tz_event, COALESCE(st.tz_end, now())) && tstzrange(bfs.inicio, bfs.fim)) AND (bfs.id_equipment = st.id_equipment))))
          ORDER BY st.id_equipment, GREATEST(st.tz_event, bfs.inicio), bfs.inicio
        ), stops_final AS (
         SELECT stpf.turno_hrs,
            stpf.shift_start_time,
            stpf.id_equipment,
            stpf.cd_shift,
            stpf.ts_value_production,
            stpf.id_order,
            stpf.inicio,
            stpf.fim,
            stpf.id_site,
            stpf.id_area,
            stpf.id_shift,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 0) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_0,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 1) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_1,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 2) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_2,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 3) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_3,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 4) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_4,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 5) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_5,
            COALESCE(sum(
                CASE
                    WHEN (st.downtimereason = 6) THEN date_part('epoch'::text, (st.tz_end - st.tz_event))
                    ELSE NULL::double precision
                END), (0)::double precision) AS dt_6
           FROM (base_for_splits stpf
             LEFT JOIN split_bfs st ON (((st.tz_event < stpf.fim) AND (st.tz_end > stpf.inicio) AND (stpf.id_equipment = st.id_equipment))))
          GROUP BY stpf.turno_hrs, stpf.shift_start_time, stpf.id_equipment, stpf.cd_shift, stpf.ts_value_production, stpf.id_order, stpf.inicio, stpf.fim, stpf.id_site, stpf.id_area, stpf.id_shift
          ORDER BY stpf.id_equipment, stpf.shift_start_time, stpf.inicio
        ), final_and_press AS (
         SELECT f.turno_hrs,
            f.shift_start_time,
            f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            f.inicio,
            f.fim,
            f.id_site,
            f.id_area,
            f.id_shift,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6,
            pqty.gross,
            pqty.net
           FROM (stops_final f
             LEFT JOIN press_quantity pqty ON (((f.id_equipment = pqty.id_equipment) AND ((f.cd_shift)::text = (pqty.cd_shift)::text) AND (f.ts_value_production = pqty.ts_value_production) AND (f.id_order = pqty.id_order) AND (f.inicio = pqty.inicio) AND (f.fim = pqty.fim) AND (f.id_shift = pqty.id_shift) AND (f.turno_hrs = pqty.turno_hrs))))
        ), packed_quantity AS (
         SELECT bfs.id_equipment,
            l.label_job,
            bfs.id_order,
            bfs.inicio,
            bfs.fim,
                CASE
                    WHEN (sum(l.label_amount) IS NULL) THEN (0)::double precision
                    ELSE sum(l.label_amount)
                END AS net_label,
            bfs.id_shift
           FROM (base_for_splits bfs
             LEFT JOIN labels l ON (((l.tz_value >= bfs.inicio) AND (l.tz_value < (bfs.fim - '00:00:01'::interval)) AND (l.id_equipment = bfs.id_equipment))))
          GROUP BY bfs.id_equipment, l.label_job, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift
          ORDER BY bfs.id_equipment, bfs.inicio, l.label_job
        ), press_packed_final AS (
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            f.id_order,
            (date_part('epoch'::text, (f.fim - f.inicio)))::bigint AS shift_duration,
            f.gross AS press_count,
            f.net AS net_sensor,
            pack.net_label AS packed_qty,
            pack.label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM (final_and_press f
             LEFT JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (f.id_order = (pack.label_job)::bigint))))
        UNION ALL
         SELECT f.id_equipment,
            f.cd_shift,
            f.ts_value_production,
            (pack.label_job)::bigint AS id_order,
            0 AS shift_duration,
            0 AS press_count,
            0 AS net_sensor,
            pack.net_label AS packed_qty,
            NULL::text AS label_job,
            f.id_shift,
            f.turno_hrs,
            f.shift_start_time,
            f.dt_0,
            f.dt_1,
            f.dt_2,
            f.dt_3,
            f.dt_4,
            f.dt_5,
            f.dt_6
           FROM (final_and_press f
             JOIN packed_quantity pack ON (((f.inicio = pack.inicio) AND (f.fim = pack.fim) AND (f.id_equipment = pack.id_equipment) AND (pack.net_label IS NOT NULL) AND (pack.net_label <> (0)::double precision) AND (f.id_order <> (pack.label_job)::bigint))))
  ORDER BY 1, 3, 2
        ), shift_report AS (
         SELECT ppf.id_equipment,
            eq.cd_equipment AS line,
            ppf.cd_shift AS shift,
            ppf.turno_hrs AS shift_hrs,
            ppf.ts_value_production AS day,
            ppf.id_order AS job,
            (ppf.shift_duration)::double precision AS shift_duration,
            (((ppf.shift_duration)::double precision / (3600)::double precision))::numeric(10,2) AS shift_duration_s,
            (((((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_6) / (3600)::double precision))::numeric(10,2) AS total_dt_s,
            ((((ppf.shift_duration)::double precision - (((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_6)) / (3600)::double precision))::numeric(10,2) AS running_s,
            (((ppf.dt_0 + ppf.dt_4) / (3600)::double precision))::numeric(10,2) AS dt_0,
            ((ppf.dt_1 / (3600)::double precision))::numeric(10,2) AS dt_1,
            ((ppf.dt_2 / (3600)::double precision))::numeric(10,2) AS dt_2,
            ((ppf.dt_3 / (3600)::double precision))::numeric(10,2) AS dt_3,
            ((ppf.dt_6 / (3600)::double precision))::numeric(10,2) AS dt_4,
            COALESCE((ppf.press_count)::double precision, (0)::double precision) AS prss_qty,
            COALESCE((ppf.net_sensor)::double precision, (0)::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, (0)::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone(serving.report_tz(p_id_enterprise, 'sap_sync_deb'), lower(pos.runtime_timerange_new)) AS job_sequence
           FROM (((press_packed_final ppf
             LEFT JOIN equipments eq ON (((ppf.id_equipment = eq.id_equipment) AND (eq.id_enterprise = p_id_enterprise) AND (eq.tp_equipment = 3))))
             LEFT JOIN shifts shi ON (((shi.id_shift = ppf.id_shift) AND (shi.id_enterprise = p_id_enterprise))))
             LEFT JOIN po_sequence pos ON (((ppf.id_order = pos.id_order) AND (tstzrange(ppf.shift_start_time, (ppf.shift_start_time + '12:00:00'::interval)) && pos.runtime_timerange_new))))
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM customer_reports.boxes ebc
          WHERE ((ebc.customer_id = p_id_enterprise) AND (ebc.label_key = COALESCE((serving.report_config(p_id_enterprise) ->> 'label_key'::text), 'Label_Neopac'::text)) AND (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = p_id_enterprise) AND (equipments.id_site = any(serving.report_sites(p_id_enterprise, 'sap_sync_deb'))) AND (equipments.tp_equipment = 3)))) AND (ebc.ts_value >= (now() - '4 days'::interval)))
          ORDER BY ebc.id_equipment, ebc.ts_value
        ), final_labels AS (
         SELECT eq.cd_equipment,
            t.turno_hrs,
            t.shift_start_time,
            t.id_equipment,
            t.cd_shift,
            t.id_shift,
            t.ts_value_production,
            t.tz_value,
            t.tz_end,
            ld.id_order,
            sum(ld.net_production) AS sum_labels
           FROM ((turnos t
             LEFT JOIN labels_data ld ON (((t.id_equipment = ld.id_equipment) AND (ld.ts_value >= t.tz_value) AND (ld.ts_value < t.tz_end))))
             LEFT JOIN equipments eq ON ((eq.id_equipment = t.id_equipment)))
          GROUP BY eq.cd_equipment, t.turno_hrs, t.shift_start_time, t.id_equipment, t.cd_shift, t.id_shift, t.ts_value_production, t.tz_value, t.tz_end, ld.id_order
          ORDER BY t.id_equipment, t.shift_start_time
        ), final_jobs AS (
         SELECT shift_report.prss_qty AS rumpfe,
            shift_report.net_sensor AS gutmenge,
            shift_report.dt_0 AS rustzeit,
            shift_report.shift_duration_s AS produktionszeit,
            shift_report.dt_2 AS geplante_ausfallzeit,
            shift_report.dt_1 AS ungeplante_ausfallzeit,
            shift_report.dt_3 AS matfehler_ausfallzeit,
            shift_report.dt_4 AS no_order,
            shift_report.job AS auftrag,
            shift_report.line AS linie,
            shift_report.shift AS shicht,
            shift_report.shift_number AS shicht_nummer,
            shift_report.job_sequence AS auftrag_startzeit,
            shift_report.day AS tag,
            shift_report.running_s AS running_h,
            shift_report.shift_start_time
           FROM shift_report
          ORDER BY shift_report.line, shift_report.day, shift_report.shift_number, shift_report.job_sequence
        ), final1 AS (
         SELECT fl.id_order,
            fl.sum_labels,
            fj.rumpfe,
            fj.gutmenge,
            fj.rustzeit,
            fj.produktionszeit,
            fj.geplante_ausfallzeit,
            fj.ungeplante_ausfallzeit,
            fj.matfehler_ausfallzeit,
            fj.no_order,
            fj.auftrag,
            fj.linie,
            fj.shicht,
            fj.shicht_nummer,
            fj.auftrag_startzeit,
            fj.tag,
            fj.running_h,
            fj.shift_start_time
           FROM (final_jobs fj
             LEFT JOIN final_labels fl ON ((((fl.cd_equipment)::text = (fj.linie)::text) AND ((fl.id_order)::integer = fj.auftrag) AND (fl.ts_value_production = fj.tag) AND ((fl.cd_shift)::text = (fj.shicht)::text))))
        ), missing_jobs_labels AS (
         SELECT fl.cd_equipment,
            fl.turno_hrs,
            fl.shift_start_time,
            fl.id_equipment,
            fl.cd_shift,
            fl.id_shift,
            fl.ts_value_production,
            fl.tz_value,
            fl.tz_end,
            fl.id_order,
            fl.sum_labels,
            f1.id_order AS job
           FROM (final_labels fl
             LEFT JOIN final1 f1 ON ((((fl.cd_equipment)::text = (f1.linie)::text) AND ((fl.id_order)::integer = f1.auftrag) AND (fl.ts_value_production = f1.tag) AND ((fl.cd_shift)::text = (f1.shicht)::text))))
          WHERE ((fl.sum_labels IS NOT NULL) AND (f1.id_order IS NULL))
        ), final10 AS (
         SELECT 'normal'::text AS data_type,
            final1.id_order AS id_order_label,
            final1.sum_labels,
            final1.rumpfe,
            final1.gutmenge,
            final1.rustzeit,
            final1.produktionszeit,
            final1.geplante_ausfallzeit,
            final1.ungeplante_ausfallzeit,
            final1.matfehler_ausfallzeit,
            final1.no_order,
            final1.auftrag,
            final1.linie,
            final1.shicht,
            final1.shicht_nummer,
            final1.auftrag_startzeit,
            final1.tag,
            final1.running_h,
            final1.shift_start_time
           FROM final1
        UNION ALL
         SELECT 'missing_job'::text AS data_type,
            missing_jobs_labels.id_order AS id_order_label,
            missing_jobs_labels.sum_labels,
            0 AS rumpfe,
            0 AS gutmenge,
            0 AS rustzeit,
            0 AS produktionszeit,
            0 AS geplante_ausfallzeit,
            0 AS ungeplante_ausfallzeit,
            0 AS matfehler_ausfallzeit,
            0 AS no_order,
            NULL::bigint AS auftrag,
            missing_jobs_labels.cd_equipment AS linie,
            missing_jobs_labels.cd_shift AS shicht,
                CASE
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Frühschicht'::text) THEN 1
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Spätschicht'::text) THEN 2
                    WHEN ((missing_jobs_labels.cd_shift)::text = 'Nachtschicht'::text) THEN 3
                    ELSE NULL::integer
                END AS shicht_nummer,
            NULL::timestamp with time zone AS auftrag_startzeit,
            missing_jobs_labels.ts_value_production AS tag,
            0 AS running_h,
            missing_jobs_labels.shift_start_time
           FROM missing_jobs_labels
  ORDER BY 13, 17, 15
        ), final11 AS (
         SELECT DISTINCT ON (final10.linie, final10.tag, final10.shicht, COALESCE(final10.auftrag, (0)::bigint)) final10.linie,
            final10.tag,
            final10.shicht,
            final10.shicht_nummer,
            COALESCE(final10.auftrag, (0)::bigint) AS auftrag_key,
            final10.auftrag,
            final10.sum_labels,
            final10.rumpfe,
            final10.sum_labels AS gutmenge,
            final10.rustzeit,
            final10.produktionszeit,
            final10.geplante_ausfallzeit,
            final10.ungeplante_ausfallzeit,
            final10.matfehler_ausfallzeit,
            final10.no_order,
            final10.auftrag_startzeit,
            final10.running_h,
            final10.shift_start_time,
            final10.data_type,
            final10.id_order_label
           FROM final10
          WHERE (final10.tag >= (timezone(serving.report_tz(p_id_enterprise, 'sap_sync_deb'), now()) - '3 days'::interval))
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge,
    final11.rustzeit,
    final11.produktionszeit,
    final11.geplante_ausfallzeit,
    final11.ungeplante_ausfallzeit,
    final11.matfehler_ausfallzeit,
    final11.no_order,
    (final11.auftrag_startzeit)::timestamp without time zone AS auftrag_startzeit,
    final11.running_h,
    final11.shift_start_time,
    final11.data_type,
    final11.id_order_label
   FROM final11
   ) AS deb_branch
$function$;

RESET check_function_bodies;
