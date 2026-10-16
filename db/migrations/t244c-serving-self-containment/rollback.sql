-- ============================================================================
-- t244c :: ROLLBACK — restores the 6 dropped legacy objects AND reverts the 3
-- serving.* function bodies to their pre-t244c (t244 01-expand) definitions.
-- Recreate order honours dependencies (equipment_boxes -> _deb -> main13).
-- Also removes the sap_sync_deb / label_key config keys seeded by 01-sap-inline.
-- ============================================================================
SET client_min_messages = warning;

-- 1) Recreate stub tables (Piece B)
CREATE TABLE IF NOT EXISTS public.v_13_overview_takt (
    id_equipment integer, id_enterprise integer, id_site integer, avg_speed integer
);
CREATE TABLE IF NOT EXISTS public.v_13_overview_partial_scrap_rate (
    cd_equipment character varying, id_enterprise integer, id_site integer, id_equipment integer,
    gross double precision, net double precision, scrap double precision, scrap_rate numeric
);

-- 2) Recreate SAP views (Piece A) in dependency order
CREATE OR REPLACE VIEW customer_reports.equipment_boxes_cust_13 AS
SELECT boxes.ts_value,
    boxes.id_order,
    boxes.id_equipment,
    boxes.id_area,
    boxes.id_site,
    13 AS id_enterprise,
    boxes.net_production,
    boxes.qty
   FROM boxes
  WHERE ((boxes.customer_id = 13) AND (boxes.label_key = 'Label_Neopac'::text));

CREATE OR REPLACE VIEW customer_reports.v_sap_report_data_sync_customer_13_deb AS
WITH dias AS (
         SELECT (generate_series(((timezone('Europe/Zurich'::text, now()))::date - '4 days'::interval), ((timezone('Europe/Zurich'::text, now()))::date)::timestamp without time zone, '1 day'::interval))::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(((timezone('Europe/Zurich'::text, ers.ts_value))::time without time zone)::interval, 'HH24:MI'::text), '-', to_char(((timezone('Europe/Zurich'::text, ers.ts_end))::time without time zone)::interval, 'HH24:MI'::text)) AS turno_hrs,
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (ers.ts_value_production >= scd.start_day) AND (ers.ts_value <= now()) AND (shi.id_shift = ers.id_shift))
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))))
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
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.id_site = 29) AND (equipments_1.tp_equipment = 3))))
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))) AND (agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval)) AND (agg_equipment_values_1min.ts_value >= scd.start_day) AND (agg_equipment_values_1min.id_enterprise = 13) AND (agg_equipment_values_1min.id_site = 29))
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (po.id_equipment = porun.id_equipment) AND (po.id_enterprise = 13) AND (po.id_production_order = porun.id_production_order) AND (lower(porun.runtime_timerange) >= (now() - '90 days'::interval)))
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
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.tp_equipment = 3) AND (equipments_1.id_site = 29))))
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
             LEFT JOIN equipments e ON (((ee.id_equipment = e.id_equipment) AND (e.id_enterprise = 13) AND (e.tp_equipment = 3) AND (e.id_site = 29))))
             LEFT JOIN downtime_codes dc ON (((ee.cd_category)::text = dc.description)))
          WHERE ((ee.status = 10) AND (ee.ts_event >= (now() - '90 days'::interval)) AND (tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange((now() - '4 days'::interval), now())) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))))
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
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM (((press_packed_final ppf
             LEFT JOIN equipments eq ON (((ppf.id_equipment = eq.id_equipment) AND (eq.id_enterprise = 13) AND (eq.tp_equipment = 3))))
             LEFT JOIN shifts shi ON (((shi.id_shift = ppf.id_shift) AND (shi.id_enterprise = 13))))
             LEFT JOIN po_sequence pos ON (((ppf.id_order = pos.id_order) AND (tstzrange(ppf.shift_start_time, (ppf.shift_start_time + '12:00:00'::interval)) && pos.runtime_timerange_new))))
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE ((ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))) AND (ebc.ts_value >= (now() - '4 days'::interval)))
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
          WHERE (final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval))
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
   FROM final11;

CREATE OR REPLACE VIEW customer_reports.v_13_site_deb_sap_report AS
WITH dias AS (
         SELECT (generate_series(((timezone('Europe/Budapest'::text, now()))::date - '3 days'::interval), ((timezone('Europe/Budapest'::text, now()))::date)::timestamp without time zone, '1 day'::interval))::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(((timezone('Europe/Budapest'::text, equipment_oee_shift.ts_value))::time without time zone)::interval, 'HH24:MI'::text), '-', to_char(((timezone('Europe/Budapest'::text, equipment_oee_shift.ts_end))::time without time zone)::interval, 'HH24:MI'::text)) AS turno_hrs,
            equipment_oee_shift.ts_value AS shift_start_time,
            equipment_oee_shift.id_equipment,
            equipment_oee_shift.cd_shift,
            equipment_oee_shift.id_shift,
            equipment_oee_shift.ts_value_production,
            equipment_oee_shift.ts_value AS tz_value,
                CASE
                    WHEN (equipment_oee_shift.ts_end > now()) THEN now()
                    ELSE equipment_oee_shift.ts_end
                END AS tz_end
           FROM equipment_oee_shift,
            start_counting_day scd
          WHERE ((equipment_oee_shift.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (equipment_oee_shift.ts_value_production >= scd.start_day) AND (equipment_oee_shift.ts_value < now()))
          ORDER BY equipment_oee_shift.id_equipment, equipment_oee_shift.ts_value
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))))
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
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.id_site = 29) AND (equipments_1.tp_equipment = 3))))
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))) AND (agg_equipment_values_1min.ts_value >= (now() - '3 days'::interval)) AND (agg_equipment_values_1min.ts_value >= scd.start_day) AND (agg_equipment_values_1min.id_enterprise = 13) AND (agg_equipment_values_1min.id_site = 29))
        ), labels_extract AS (
         SELECT NULL::timestamp with time zone AS tz_value,
            NULL::integer AS id_equipment,
            NULL::text AS label_job,
            NULL::double precision AS label_amount
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 29)))) AND (po.id_equipment = porun.id_equipment) AND (po.id_enterprise = 13) AND (po.id_production_order = porun.id_production_order) AND (lower(porun.runtime_timerange) >= (now() - '90 days'::interval)))
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), negative_labels AS (
         SELECT l.tz_value,
            l.id_equipment,
            l.label_job,
            l.label_amount,
            po.job_end,
                CASE
                    WHEN (po.job_end IS NULL) THEN (0)::bigint
                    ELSE (date_part('epoch'::text, (l.tz_value - po.job_end)))::bigint
                END AS diff_s
           FROM (labels_extract l
             LEFT JOIN prod_orders po ON (((l.label_job)::integer = po.id_order)))
        ), labels AS (
         SELECT DISTINCT negative_labels.tz_value,
            negative_labels.id_equipment,
            negative_labels.label_job,
            negative_labels.label_amount
           FROM negative_labels
          WHERE (negative_labels.diff_s <= 10800)
          ORDER BY negative_labels.tz_value
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
             LEFT JOIN presscount pc ON (((pc.tz_value >= bfs.inicio) AND (pc.tz_value <= bfs.fim) AND (pc.id_equipment = bfs.id_equipment) AND (pc.id_site = bfs.id_site) AND (pc.id_area = bfs.id_area))))
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.tp_equipment = 3) AND (equipments_1.id_site = 29))))
        ), category_level AS (
         SELECT top_level.id_equipment,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text) AS description,
            ((jsonb_array_elements((top_level.elem -> 'categories'::text)) ->> 'code'::text))::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements((top_level.elem -> 'categories'::text)) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes AS (
         SELECT DISTINCT category_level."position",
            category_level.description,
            category_level.id_equipment
           FROM category_level
          ORDER BY category_level.id_equipment, category_level."position"
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            ee.planned_downtime,
            dc."position" AS code,
                CASE
                    WHEN (dc."position" = 24) THEN 1
                    WHEN (dc."position" = 2) THEN 2
                    WHEN (dc."position" = ANY (ARRAY[5, 8])) THEN 3
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) >= (COALESCE(e.stop_threshold_time, 0))::double precision)) THEN 4
                    WHEN ((dc."position" IS NULL) AND (date_part('epoch'::text, (COALESCE(ee.ts_end, now()) - ee.ts_event)) < COALESCE((e.stop_threshold_time)::double precision, 'Infinity'::double precision))) THEN 5
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM ((equipment_events ee
             LEFT JOIN equipments e ON (((ee.id_equipment = e.id_equipment) AND (e.id_enterprise = 13) AND (e.tp_equipment = 3) AND (e.id_site = 29))))
             LEFT JOIN downtime_codes dc ON ((((ee.cd_category)::text = dc.description) AND (ee.id_equipment = dc.id_equipment))))
          WHERE ((ee.status = 10) AND (ee.ts_event >= (now() - '15 days'::interval)) AND (tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange((now() - '3 days'::interval), now())) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 29) AND (equipments.tp_equipment = 3)))))
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
                END), (0)::double precision) AS dt_5
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
             LEFT JOIN labels l ON (((l.tz_value >= bfs.inicio) AND (l.tz_value <= (bfs.fim - '00:00:01'::interval)) AND (l.id_equipment = bfs.id_equipment))))
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
            f.dt_5
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
            f.dt_5
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
            (((((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_5) / (3600)::double precision))::numeric(10,2) AS total_dt_s,
            ((((ppf.shift_duration)::double precision - (((((ppf.dt_0 + ppf.dt_1) + ppf.dt_2) + ppf.dt_3) + ppf.dt_4) + ppf.dt_5)) / (3600)::double precision))::numeric(10,2) AS running_s,
            (((ppf.dt_0 + ppf.dt_5) / (3600)::double precision))::numeric(10,2) AS dt_0,
            ((ppf.dt_1 / (3600)::double precision))::numeric(10,2) AS dt_1,
            ((ppf.dt_2 / (3600)::double precision))::numeric(10,2) AS dt_2,
            ((ppf.dt_3 / (3600)::double precision))::numeric(10,2) AS dt_3,
            ((ppf.dt_4 / (3600)::double precision))::numeric(10,2) AS dt_4,
            COALESCE((ppf.press_count)::double precision, (0)::double precision) AS prss_qty,
            COALESCE((ppf.net_sensor)::double precision, (0)::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, (0)::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            timezone('Europe/Budapest'::text, ppf.shift_start_time) AS shift_start_time,
            timezone('Europe/Budapest'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM (((press_packed_final ppf
             LEFT JOIN equipments eq ON (((ppf.id_equipment = eq.id_equipment) AND (eq.id_enterprise = 13) AND (eq.tp_equipment = 3))))
             LEFT JOIN shifts shi ON (((shi.id_shift = ppf.id_shift) AND (shi.id_enterprise = 13))))
             LEFT JOIN po_sequence pos ON (((ppf.id_order = pos.id_order) AND (tstzrange(ppf.shift_start_time, (ppf.shift_start_time + '12:00:00'::interval)) && pos.runtime_timerange_new))))
        )
 SELECT shift_report.line,
    shift_report.shift,
    shift_report.shift_hrs,
    shift_report.day,
    shift_report.job,
    shift_report.prss_qty AS gross,
    shift_report.net_sensor AS net,
    shift_report.running_s AS gyartasi_ido,
    shift_report.dt_0 AS beallitasi_ido,
    shift_report.dt_1 AS muszaki_hiba,
    shift_report.dt_2 AS tervezett_karb,
    shift_report.dt_3 AS anyagproblema,
    shift_report.dt_4 AS nem_indokolt_ido,
    shift_report.total_dt_s AS total_dt,
    shift_report.job_sequence AS job_start,
    shift_report.shift_start_time,
    shift_report.shift_number,
    shift_report.id_equipment,
    13 AS id_eterprise
   FROM shift_report
  WHERE (shift_report.day >= (timezone('Europe/Budapest'::text, now()) - '2 days'::interval));

CREATE OR REPLACE VIEW customer_reports.v_sap_report_data_sync_customer_13 AS
WITH dias AS (
         SELECT (generate_series(((timezone('Europe/Zurich'::text, now()))::date - '4 days'::interval), ((timezone('Europe/Zurich'::text, now()))::date)::timestamp without time zone, '1 day'::interval))::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(((timezone('Europe/Zurich'::text, ers.ts_value))::time without time zone)::interval, 'HH24:MI'::text), '-', to_char(((timezone('Europe/Zurich'::text, ers.ts_end))::time without time zone)::interval, 'HH24:MI'::text)) AS turno_hrs,
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 13)))) AND (ers.ts_value_production >= scd.start_day) AND (ers.ts_value <= now()) AND (shi.id_shift = ers.id_shift))
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))))
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
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.id_site = 13) AND (equipments_1.tp_equipment = 3))))
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = 3)))) AND (agg_equipment_values_1min.ts_value >= (now() - '4 days'::interval)) AND (agg_equipment_values_1min.ts_value >= scd.start_day) AND (agg_equipment_values_1min.id_enterprise = 13) AND (agg_equipment_values_1min.id_site = 13))
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
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.tp_equipment = 3) AND (equipments.id_site = 13)))) AND (po.id_equipment = porun.id_equipment) AND (po.id_enterprise = 13) AND (po.id_production_order = porun.id_production_order) AND (lower(porun.runtime_timerange) >= (now() - '90 days'::interval)))
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
                  WHERE ((equipments_1.id_enterprise = 13) AND (equipments_1.tp_equipment = 3) AND (equipments_1.id_site = 13))))
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
             LEFT JOIN equipments e ON (((ee.id_equipment = e.id_equipment) AND (e.id_enterprise = 13) AND (e.tp_equipment = 3) AND (e.id_site = 13))))
             LEFT JOIN downtime_codes dc ON (((ee.cd_category)::text = dc.description)))
          WHERE ((ee.status = 10) AND (ee.ts_event >= (now() - '90 days'::interval)) AND (tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange((now() - '4 days'::interval), now())) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = 3)))))
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
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM (((press_packed_final ppf
             LEFT JOIN equipments eq ON (((ppf.id_equipment = eq.id_equipment) AND (eq.id_enterprise = 13) AND (eq.tp_equipment = 3))))
             LEFT JOIN shifts shi ON (((shi.id_shift = ppf.id_shift) AND (shi.id_enterprise = 13))))
             LEFT JOIN po_sequence pos ON (((ppf.id_order = pos.id_order) AND (tstzrange(ppf.shift_start_time, (ppf.shift_start_time + '12:00:00'::interval)) && pos.runtime_timerange_new))))
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE ((ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE ((equipments.id_enterprise = 13) AND (equipments.id_site = 13) AND (equipments.tp_equipment = 3)))) AND (ebc.ts_value >= (now() - '4 days'::interval)))
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
          WHERE (final10.tag >= (timezone('Europe/Zurich'::text, now()) - '3 days'::interval))
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
UNION ALL
 SELECT v_sap_report_data_sync_customer_13_deb.linie,
    v_sap_report_data_sync_customer_13_deb.tag,
    v_sap_report_data_sync_customer_13_deb.shicht,
    v_sap_report_data_sync_customer_13_deb.shicht_nummer,
    v_sap_report_data_sync_customer_13_deb.auftrag,
    v_sap_report_data_sync_customer_13_deb.sum_labels,
    v_sap_report_data_sync_customer_13_deb.rumpfe,
    v_sap_report_data_sync_customer_13_deb.gutmenge,
    v_sap_report_data_sync_customer_13_deb.rustzeit,
    v_sap_report_data_sync_customer_13_deb.produktionszeit,
    v_sap_report_data_sync_customer_13_deb.geplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.ungeplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.matfehler_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.no_order,
    v_sap_report_data_sync_customer_13_deb.auftrag_startzeit,
    v_sap_report_data_sync_customer_13_deb.running_h,
    v_sap_report_data_sync_customer_13_deb.shift_start_time,
    v_sap_report_data_sync_customer_13_deb.data_type,
    v_sap_report_data_sync_customer_13_deb.id_order_label
   FROM v_sap_report_data_sync_customer_13_deb;

-- 3) Revert function bodies to pre-t244c (they reference the recreated legacy objects)
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION serving.overview_takt(p_id_enterprise integer)
RETURNS TABLE(id_equipment integer, id_enterprise integer, id_site integer, avg_speed integer)
LANGUAGE sql STABLE AS $function$
  SELECT id_equipment, id_enterprise, id_site, avg_speed
  FROM v_13_overview_takt
  WHERE id_enterprise = p_id_enterprise
$function$;;

CREATE OR REPLACE FUNCTION serving.overview_scrap_rate(p_id_enterprise integer)
RETURNS TABLE(cd_equipment character varying, id_enterprise integer, id_site integer, id_equipment integer,
              gross double precision, net double precision, scrap double precision, scrap_rate numeric)
LANGUAGE sql STABLE AS $function$
  SELECT cd_equipment, id_enterprise, id_site, id_equipment, gross, net, scrap, scrap_rate
  FROM v_13_overview_partial_scrap_rate
  WHERE id_enterprise = p_id_enterprise
$function$;;

CREATE OR REPLACE FUNCTION serving.data_sync(p_id_enterprise integer, p_numdays integer DEFAULT NULL::integer)
RETURNS TABLE(site character varying, line character varying, shift character varying,
    shiftstartdate timestamp with time zone, job bigint, item character varying,
    totalavailablehrsinmin numeric(10,2), dtimehrsplannedinmin numeric(10,2), dtimehrsunplannedinmin numeric(10,2),
    unplanneddt_proinmin numeric(10,2), unplanneddt_resinmin numeric(10,2), unplanneddt_mntinmin numeric(10,2),
    setuphoursinmin numeric(10,2), runhoursinmin numeric(10,2), presscnt bigint, packcnt bigint,
    jobstatus character varying, jobstartdate timestamp with time zone, jobcompleteddate timestamp with time zone,
    createddate timestamp with time zone, updateddate timestamp with time zone, packiotid character varying,
    supervisorapproval boolean, supervisorapproveddate timestamp with time zone, supervisornotes jsonb,
    nm_user_validation character varying, id_validation bigint, ts_creation timestamp with time zone,
    to_delete boolean, last_update timestamp with time zone, packml_topic character varying,
    last_update_prod_data timestamp with time zone)
LANGUAGE sql STABLE AS $function$
SELECT
  c1::character varying,
  c2::character varying,
  c3::character varying,
  c4::timestamp with time zone,
  c5::bigint,
  c6::character varying,
  c7::numeric(10,2),
  c8::numeric(10,2),
  c9::numeric(10,2),
  c10::numeric(10,2),
  c11::numeric(10,2),
  c12::numeric(10,2),
  c13::numeric(10,2),
  c14::numeric(10,2),
  c15::bigint,
  c16::bigint,
  c17::character varying,
  c18::timestamp with time zone,
  c19::timestamp with time zone,
  c20::timestamp with time zone,
  c21::timestamp with time zone,
  c22::character varying,
  c23::boolean,
  c24::timestamp with time zone,
  c25::jsonb,
  c26::character varying,
  c27::bigint,
  c28::timestamp with time zone,
  c29::boolean,
  c30::timestamp with time zone,
  c31::character varying,
  c32::timestamp with time zone
FROM (
--novo report 
--versao anterior de 2023-10-05 funcionando, salva por eduardo
--novo report 
with data_sync as (
 select 
 	eqvs.ts_value_production as day,
    s.nm_site::varchar(15) as Site,
    s.id_site,
    eqvs.cd_equipment::varchar(6) as line,
    --rse.line::varchar(6),
    eqvs.cd_shift::varchar(6) as shift,
    eqvs.shift_start_time as ShiftStartDate,    
    --rse.shift_start_time at time zone serving.report_tz(p_id_enterprise) as ShiftStartDate, 
    eqvs.id_order as job,
    ((rse.shift_duration_h-rse.setup_duration_h-rse.dt_plan_h)*60)::NUMERIC(10,1) as TotalAvailableHrsinMin,
    ((rse.dt_plan_h)*60)::NUMERIC(10,1) as DTimeHrsPlannedinMin,
    ((rse.dt_unplan_h)*60)::NUMERIC(10,1) as DTimeHrsUnPlannedinMin,
    ((rse.setup_duration_h)*60)::NUMERIC(10,1) as SetupHoursinMin,
    ((rse.running)*60)::NUMERIC(10,1) as RunHoursinMin,
    rse.prss_qty::bigint as PressCnt,
    rse.packed_qty::bigint as PackCnt,
    pr.packml_topic,
    (case 
        when po.status = 1 then 'available' 
        when po.status = 2 then 'in_progress' 
        when po.status = 3 then 'completed'
        when po.status = 4 then 'paused' 
    end)::varchar(20) as JobStatus,
    lower(por.runtime_timerange)  as JobStartDate,
    upper(por.runtime_timerange) as JobCompletedDate,
    po.ts_creation as CreatedDate,
    case when po.status = 2 then po.last_update else coalesce(po.ts_start_tz,po.last_update,eqvs.ts_creation) end as UpdatedDate,
    eqvs.index1::varchar(25),
    (po.custom_field ->> 'cd_product')::varchar(30) AS cd_product,
 	eqvs.txt_validation_notes,
 	eqvs.validation::bool,
 	eqvs.ts_user_validation,
 	eqvs.nm_user_validation::varchar(15),
 	eqvs.id_validation::bigint,
 	eqvs.ts_creation,
 	eqvs.to_delete,
 	eqvs.last_update,
 	((rse.pro_h)*60)::NUMERIC(10,1) as UnplannedDT_PROinMin,
 	((rse.res_h)*60)::NUMERIC(10,1) as UnplannedDT_RESinMin,
 	((rse.mnt_h)*60)::NUMERIC(10,1) as UnplannedDT_MNTinMin
from equipment_validation_shift eqvs --(aqui paga do relatorio)
left join report_shift_enterprsie_06 rse
on rse.index1 = eqvs.index1
and rse.day >= now() - interval '101 day' --de 41 pra 71 edu 10-fev-25)
left join equipments eq
on eqvs.cd_equipment = eq.nm_equipment and eq.id_enterprise = p_id_enterprise and eq.tp_equipment = 3
left join sites s
on eq.id_site = s.id_site
left join production_orders po
on po.id_equipment = eq.id_equipment 
and po.id_order = eqvs.id_order
and po.id_enterprise = p_id_enterprise
and po.last_update >= now() - interval '5 month'  --de 3 pra 4 edu 10-fev-25)
left join production_orders_runtime por
on por.id_equipment = eq.id_equipment 
and po.id_production_order = por.id_production_order 
and lower(por.runtime_timerange) at time zone serving.report_tz(p_id_enterprise) = rse.job_sequence
and por.runtime_timerange && tstzrange(now() - interval '6 month', now())--de 4 pra 5 edu 10-fev-25)
left join packml_register pr
on pr.id_equipment = eq.id_equipment
and pr.id_enterprise = p_id_enterprise
where eqvs.ts_value_production >= now() - interval '100 day' --de 40 pra 70 edu 10-fev-25)
order by rse.line, rse.day desc, rse.shift_number desc, rse.job_sequence desc
)
        select 
            Site,
            line,
            shift,
            ShiftStartDate,
            job,
            cd_product as Item,				--esse eh a info do produto que a celine pediu
            TotalAvailableHrsinMin,
            DTimeHrsPlannedinMin,
            DTimeHrsUnPlannedinMin,
            UnplannedDT_PROinMin,
 			UnplannedDT_RESinMin,
 			UnplannedDT_MNTinMin,
            SetupHoursinMin,
            RunHoursinMin,
            PressCnt,
            PackCnt,
            JobStatus,
            JobStartDate,
            JobCompletedDate,
            CreatedDate,
            UpdatedDate,
            index1 as PackIOTID,
            validation as SupervisorApproval,				-- true para validado
    		ts_user_validation as SupervisorApprovedDate,		--timestamp do horario da valiação os dados
 			txt_validation_notes as SupervisorNotes,	--o note que o supervisor escreveu na validacao dos dados
 			nm_user_validation,		--login do usuário que validou os dados no operator
 			id_validation,			--esse é um id sequencial que em na tabela validation (acho que não precisa)
 			ts_creation,			--timestamp do hoario que a linha de dados foi criada na tabela validation (acho que não precisa)
 			to_delete,				--true para linhas de dados que deixaram de existir
 			greatest(last_update,ts_user_validation) as last_update,				--se houve algum update nos ultimos 21 dias, este horario se reflete aqui. A diferença deste é que olha linha por linha de dados enquanto o UpdatedDate anterior muda por OP,
 			packml_topic,
			last_update as last_update_prod_data
        from data_sync
        --where day >= StartDate
        --and day <= EndDate
        where day >= (now() at time zone serving.report_tz(p_id_enterprise))::date - coalesce(p_numdays,21)*(interval '1 day')
        and day <= (now() at time zone serving.report_tz(p_id_enterprise))::date
) AS s(c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15,c16,c17,c18,c19,c20,c21,c22,c23,c24,c25,c26,c27,c28,c29,c30,c31,c32)
$function$;;

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
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
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
 SELECT v_sap_report_data_sync_customer_13_deb.linie,
    v_sap_report_data_sync_customer_13_deb.tag,
    v_sap_report_data_sync_customer_13_deb.shicht,
    v_sap_report_data_sync_customer_13_deb.shicht_nummer,
    v_sap_report_data_sync_customer_13_deb.auftrag,
    v_sap_report_data_sync_customer_13_deb.sum_labels,
    v_sap_report_data_sync_customer_13_deb.rumpfe,
    v_sap_report_data_sync_customer_13_deb.gutmenge,
    v_sap_report_data_sync_customer_13_deb.rustzeit,
    v_sap_report_data_sync_customer_13_deb.produktionszeit,
    v_sap_report_data_sync_customer_13_deb.geplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.ungeplante_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.matfehler_ausfallzeit,
    v_sap_report_data_sync_customer_13_deb.no_order,
    v_sap_report_data_sync_customer_13_deb.auftrag_startzeit,
    v_sap_report_data_sync_customer_13_deb.running_h,
    v_sap_report_data_sync_customer_13_deb.shift_start_time,
    v_sap_report_data_sync_customer_13_deb.data_type,
    v_sap_report_data_sync_customer_13_deb.id_order_label
   FROM v_sap_report_data_sync_customer_13_deb
$function$;;

RESET check_function_bodies;

-- 4) Remove config keys seeded by 01-sap-inline (leave the rest of reports intact)
UPDATE core.client_descriptors
   SET descriptor = (descriptor #- '{reports,sap_sync_deb}') #- '{reports,label_key}',
       updated_at = now()
 WHERE id_enterprise = 13;
