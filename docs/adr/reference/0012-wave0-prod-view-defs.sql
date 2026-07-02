-- ADR-0012 Wave 0 — prod view definitions (ground truth capture)
--
-- Captured 2026-07-02 from prod tsp12/packiot40 via pg_get_viewdef
-- (SELECT-only, BEGIN READ ONLY). These 23 objects are plain VIEWS on
-- prod; the staging bootstrap (edge-node-red/db/00-schema.sql) had
-- materialized 15 of them as TABLES — Wave 0 flipped those back to
-- views using these exact definitions (applied 2026-07-02, all 15 OK,
-- gate: 29/29 kind-parity + SELECT probes green).
--
-- Re-apply pattern (idempotent-ish): per object,
--   BEGIN; DROP TABLE|VIEW public.<name>; CREATE VIEW ...; COMMIT;
-- v13_mobile_power_bi_direct_query depends on v_13_overview_takt +
-- v_13_overview_partial_scrap_rate — flip those three in ONE
-- transaction (dependent view first).

-- ===VIEW=== c33_downtime_events
CREATE VIEW public.c33_downtime_events AS
 WITH events AS (
         SELECT ee.id_equipment,
            ee.ts_event,
            ee.status,
            ee.id_equipment_event,
            ee.txt_downtime_notes,
            ee.idle,
            ee.idle_processed,
            ee.forced_creation_system,
            ee.fault,
            ee.fault_processed,
            ee.cd_machine,
            ee.cd_category,
            ee.cd_subcategory,
            ee.change_over,
            ee.planned_downtime,
            ee.ts_end,
            ee.duration,
            ee.id_enterprise
           FROM equipment_events ee
          WHERE ee.id_equipment = 17 AND ee.duration > 0 AND ee.status = 10 AND ee.ts_event > (now() - '60 days'::interval)
        ), inc_shifts AS (
         SELECT ers.ts_value,
            ers.oee,
            ers.recalc_needed,
            ers.oee_p,
            ers.oee_a,
            ers.oee_q,
            ers.available_time,
            ers.running_time,
            ers.stopped_time,
            ers.planned_downtime,
            ers.ideal_production,
            ers.idle_time,
            ers.idle_starved,
            ers.idle_blocked,
            ers.id_equipment,
            ers.id_shift,
            ers.id_shift_hour,
            ers.id_team,
            ers.duration,
            ers.ts_range,
            ers.gross,
            ers.net,
            ers.downtime,
            ers.changeover_time,
            ers.target
           FROM equipment_runtime_shift ers
          WHERE ers.id_equipment = 17 AND ers.ts_value > (now() - '37 days'::interval) AND ers.ts_value <= now()
        ), test AS (
         SELECT ic.ts_value,
            ic.ts_range,
            ic.duration AS sh_duration,
            sh.cd_shift,
            et.ts_event,
            et.duration,
            et.cd_category,
            et.cd_subcategory,
            et.cd_machine,
            et.change_over,
            (( SELECT ic2.ts_value
                   FROM inc_shifts ic2
                  WHERE date_trunc('day'::text, ic2.ts_value) = date_trunc('day'::text, ic.ts_value)
                  ORDER BY ic2.ts_value
                 LIMIT 1)) - date_trunc('day'::text, ic.ts_value) AS time_offset
           FROM events et
             JOIN inc_shifts ic ON et.ts_event <@ ic.ts_range
             JOIN shift_hours sh ON ic.id_shift_hour = sh.id_shift_hour
        ), final AS (
         SELECT (t.ts_event - t.time_offset)::date AS dia,
            t.cd_shift AS turno,
            t.ts_event,
            t.cd_machine,
            t.cd_category,
            t.cd_subcategory,
            t.duration
           FROM test t
          ORDER BY t.ts_event DESC
        )
 SELECT timezone('America/Sao_Paulo'::text, final.ts_event) AS tz_event,
    final.dia,
    final.turno,
    final.ts_event,
    final.cd_machine,
    final.cd_category,
    final.cd_subcategory,
    final.duration,
        CASE
            WHEN final.duration < 90 THEN 1
            ELSE 0
        END AS microstop
   FROM final;
;
-- ===VIEW=== c33_setup_time_adjusted
CREATE VIEW public.c33_setup_time_adjusted AS
 WITH f_data AS (
         SELECT ct.ts_value,
            ct.id_equipment,
            ct.net_production_incr,
            ct.speed,
            ct.state,
            ct.mode,
            ct.sub_mode,
            ct.id_production_order,
                CASE
                    WHEN ct.mode = 6 AND lead(ct.id_production_order) OVER ord <> ct.id_production_order THEN true
                    ELSE NULL::boolean
                END AS is_interrupted
           FROM ( SELECT timezone('America/Sao_Paulo'::text, ev.ts_value) AS ts_value,
                    ev.id_equipment,
                    ev.net_production_incr,
                    ev.speed,
                    gapfill(ev.state) OVER (ORDER BY ev.id_equipment, ev.ts_value) AS state,
                    gapfill(ev.mode) OVER (ORDER BY ev.id_equipment, ev.ts_value) AS mode,
                    gapfill(ev.sub_mode) OVER (ORDER BY ev.id_equipment, ev.ts_value) AS sub_mode,
                    gapfill(ev.id_production_order) OVER (ORDER BY ev.id_equipment, ev.ts_value) AS id_production_order
                   FROM equipment_values ev
                  WHERE ev.ts_value > (now() - '60 days'::interval) AND ev.id_equipment = 17) ct
          WINDOW ord AS (ORDER BY ct.id_equipment, ct.ts_value)
        ), cl_data AS (
         SELECT f.ts_value,
            f.id_equipment,
            f.net_production_incr,
            f.speed,
            f.state,
            f.mode,
            f.sub_mode,
            f.id_production_order,
            f.is_interrupted,
                CASE
                    WHEN count(f.sub_mode) FILTER (WHERE f.mode = 6) OVER test > 0 AND f.mode = 1 THEN true
                    ELSE false
                END AS is_wrong
           FROM f_data f
          WHERE f.sub_mode IS NOT NULL AND NOT (f.id_production_order IN ( SELECT f_data.id_production_order
                   FROM f_data
                  WHERE f_data.is_interrupted IS TRUE))
          WINDOW test AS (PARTITION BY f.id_equipment, f.id_production_order ORDER BY f.ts_value ROWS BETWEEN CURRENT ROW AND 15 FOLLOWING)
        ), final AS (
         SELECT cl_data.id_equipment,
            cl_data.id_production_order,
            cl_data.mode,
            cl_data.sub_mode,
            max(cl_data.ts_value) AS t_max,
            min(cl_data.ts_value) AS t_min,
            max(cl_data.ts_value) - min(cl_data.ts_value) AS phase_duration,
            sum(max(cl_data.ts_value) - min(cl_data.ts_value)) OVER (PARTITION BY cl_data.id_equipment, cl_data.id_production_order, cl_data.mode) AS mode_duration,
            avg(cl_data.speed) AS speed,
            sum(cl_data.net_production_incr) AS net_prod
           FROM cl_data
          WHERE NOT (cl_data.id_production_order IN ( SELECT cl_data_1.id_production_order
                   FROM cl_data cl_data_1
                  WHERE cl_data_1.is_interrupted IS TRUE)) AND cl_data.is_wrong = false
          GROUP BY cl_data.id_equipment, cl_data.id_production_order, cl_data.mode, cl_data.sub_mode
          ORDER BY cl_data.id_production_order, (max(cl_data.ts_value)) DESC
        ), final2 AS (
         SELECT final.id_equipment,
            final.id_production_order,
                CASE
                    WHEN final.sub_mode::text = 'Setup Acerto'::text THEN final.t_min
                    ELSE NULL::timestamp without time zone
                END AS start_acerto,
                CASE
                    WHEN final.sub_mode::text = 'Setup Registro'::text THEN final.t_min
                    ELSE NULL::timestamp without time zone
                END AS start_registro,
                CASE
                    WHEN final.sub_mode::text = 'Setup Cor'::text THEN final.t_min
                    ELSE NULL::timestamp without time zone
                END AS start_cor,
                CASE
                    WHEN final.sub_mode::text = 'Produção'::text THEN final.t_min
                    ELSE NULL::timestamp without time zone
                END AS start_prod,
                CASE
                    WHEN final.sub_mode::text = 'Produção'::text THEN final.t_max
                    ELSE NULL::timestamp without time zone
                END AS end_prod
           FROM final
          GROUP BY final.id_equipment, final.id_production_order, final.sub_mode, final.t_min, final.t_max
        ), final3 AS (
         SELECT final2.id_equipment,
            final2.id_production_order,
            max(final2.start_acerto) AS start_acerto,
            max(final2.start_registro) AS start_registro,
            max(final2.start_cor) AS start_cor,
            max(final2.start_prod) AS start_prod,
            max(final2.end_prod) AS end_prod
           FROM final2
          GROUP BY final2.id_equipment, final2.id_production_order
          ORDER BY (max(final2.start_prod)) DESC
        ), final4 AS (
         SELECT f3.id_equipment,
            f3.id_production_order,
            timezone('America/Sao_Paulo'::text, po.ts_start) AS ts_start,
            f3.start_acerto,
            f3.start_registro,
            f3.start_cor,
            f3.start_prod,
            f3.end_prod,
            timezone('America/Sao_Paulo'::text, po.ts_end) AS ts_end
           FROM final3 f3,
            production_orders po
          WHERE f3.id_equipment = po.id_equipment AND f3.id_production_order = po.id_production_order
          ORDER BY po.ts_start DESC
        ), final5 AS (
         SELECT final4.id_equipment,
            final4.id_production_order,
            final4.ts_start,
            final4.start_acerto,
                CASE
                    WHEN final4.start_registro IS NOT NULL THEN final4.start_registro
                    WHEN final4.start_cor IS NOT NULL THEN final4.start_cor
                    ELSE final4.start_prod
                END AS end_acerto,
            final4.start_registro,
                CASE
                    WHEN final4.start_registro IS NULL THEN final4.start_registro
                    WHEN final4.start_cor IS NOT NULL THEN final4.start_cor
                    ELSE final4.start_prod
                END AS end_registro,
            final4.start_cor,
                CASE
                    WHEN final4.start_cor IS NULL THEN final4.start_cor
                    ELSE final4.start_prod
                END AS end_cor,
            final4.start_prod,
            final4.end_prod,
            final4.ts_end
           FROM final4
          GROUP BY final4.id_equipment, final4.id_production_order, final4.ts_start, final4.start_acerto, final4.start_registro, final4.start_cor, final4.start_prod, final4.end_prod, final4.ts_end
          ORDER BY final4.ts_start DESC
        ), final6 AS (
         SELECT final5.id_equipment,
            final5.id_production_order,
            final5.ts_start,
            final5.start_acerto,
            final5.end_acerto,
            final5.start_registro,
            final5.end_registro,
            final5.start_cor,
            final5.end_cor,
            final5.start_prod,
            final5.end_prod,
            final5.ts_end,
            age(final5.end_acerto, final5.ts_start) AS acerto,
            age(final5.end_registro, final5.start_registro) AS registro,
            age(final5.end_cor, final5.start_cor) AS cor,
            age(final5.start_prod, final5.ts_start) AS tot_setup,
                CASE
                    WHEN age(final5.end_registro, final5.start_registro) < '00:00:00'::interval THEN 0
                    ELSE 1
                END AS good
           FROM final5
          WHERE final5.ts_start > '2021-09-01 00:00:00'::timestamp without time zone
        ), final7 AS (
         SELECT f.id_equipment,
            f.id_production_order,
            f.ts_start,
            f.start_acerto,
            f.end_acerto,
            f.start_registro,
            f.end_registro,
            f.start_cor,
            f.end_cor,
            f.start_prod,
            f.end_prod,
            f.ts_end,
            f.acerto,
            f.registro,
            f.cor,
            f.tot_setup,
            f.good,
            sum(
                CASE
                    WHEN eqv.ts_value >= f.ts_start AND eqv.ts_value < f.ts_end THEN eqv.net_production_incr
                    ELSE 0::double precision
                END) AS prod_job,
            sum(
                CASE
                    WHEN eqv.speed < 200::double precision AND eqv.ts_value >= f.start_acerto AND eqv.ts_value < f.end_acerto THEN eqv.net_production_incr
                    ELSE 0::double precision
                END) AS prod_acerto,
            sum(
                CASE
                    WHEN eqv.speed < 200::double precision AND eqv.ts_value >= f.start_registro AND eqv.ts_value < f.end_registro THEN eqv.net_production_incr
                    ELSE 0::double precision
                END) AS prod_registro,
            sum(
                CASE
                    WHEN eqv.speed < 200::double precision AND eqv.ts_value >= f.start_cor AND eqv.ts_value < f.end_cor THEN eqv.net_production_incr
                    ELSE 0::double precision
                END) AS prod_cor,
            sum(
                CASE
                    WHEN eqv.ts_value >= f.start_prod AND eqv.ts_value < f.end_prod THEN eqv.net_production_incr
                    ELSE 0::double precision
                END) AS prod_real,
            sum(
                CASE
                    WHEN eqv.ts_value >= f.ts_start AND eqv.ts_value < f.start_prod THEN eqv.net_production_incr
                    ELSE 0::double precision
                END) AS prod_setup,
            sum(
                CASE
                    WHEN eqv.speed < 200::double precision AND eqv.ts_value >= f.ts_start AND eqv.ts_value < f.start_prod THEN eqv.net_production_incr
                    ELSE 0::double precision
                END) AS prod_setup_adj
           FROM final6 f,
            equipment_values eqv
          WHERE eqv.ts_value > '2021-09-01 03:00:00+00'::timestamp with time zone AND eqv.id_equipment = 17 AND f.good = 1
          GROUP BY f.id_equipment, f.id_production_order, f.ts_start, f.start_acerto, f.end_acerto, f.start_registro, f.end_registro, f.start_cor, f.end_cor, f.start_prod, f.end_prod, f.ts_end, f.acerto, f.registro, f.cor, f.tot_setup, f.good
          ORDER BY f.ts_start DESC
        ), final8 AS (
         SELECT f7.id_equipment,
            f7.id_production_order,
            f7.ts_start,
            f7.start_acerto,
            f7.end_acerto,
            f7.start_registro,
            f7.end_registro,
            f7.start_cor,
            f7.end_cor,
            f7.start_prod,
            f7.end_prod,
            f7.ts_end,
            f7.acerto,
            f7.registro,
            f7.cor,
            f7.tot_setup,
            f7.good,
            f7.prod_job,
            f7.prod_acerto,
            f7.prod_registro,
            f7.prod_cor,
            f7.prod_real,
            f7.prod_setup,
            f7.prod_setup_adj,
            f7.prod_real + f7.prod_setup - f7.prod_setup_adj AS prod_real_adj,
            po.production_programmed,
            po.production_final,
            po.available_time,
            po.running_time,
            po.stopped_time,
            po.planned_downtime,
            po.ideal_production,
            po.conversion_factor,
            f7.prod_real / po.production_programmed::double precision AS factor
           FROM final7 f7
             LEFT JOIN production_orders po ON f7.id_equipment = po.id_equipment AND f7.id_production_order = po.id_production_order
        )
 SELECT final8.id_equipment,
    final8.id_production_order,
    final8.ts_start,
    final8.start_acerto,
    final8.end_acerto,
    final8.start_registro,
    final8.end_registro,
    final8.start_cor,
    final8.end_cor,
    final8.start_prod,
    final8.end_prod,
    final8.ts_end,
    final8.acerto,
    final8.registro,
    final8.cor,
    final8.tot_setup,
    final8.good,
    final8.prod_job,
    final8.prod_acerto,
    final8.prod_registro,
    final8.prod_cor,
    final8.prod_real,
    final8.prod_setup,
    final8.prod_setup_adj,
    final8.prod_real_adj,
    final8.production_programmed,
    final8.production_final,
    final8.available_time,
    final8.running_time,
    final8.stopped_time,
    final8.planned_downtime,
    final8.ideal_production,
    final8.conversion_factor,
    final8.factor,
    final8.prod_setup_adj * final8.conversion_factor AS setup_kg
   FROM final8
  WHERE final8.factor < 1.2::double precision AND final8.factor > 0.3::double precision;
;
-- ===VIEW=== c35_v_dashboard_timeline
CREATE VIEW public.c35_v_dashboard_timeline AS
 SELECT e.dispositivo,
    e.json_agg,
    e.id_enterprise,
    ((e.last_status_since_array -> '-1'::integer)::character varying)::timestamp with time zone AS last_status_since,
    (e.json_agg ->> '-1'::integer)::character varying AS last_status,
    (e.ocorrencias ->> '-1'::integer)::character varying AS last_ocorrencia

   FROM ( SELECT d.dispositivo,
            json_agg(d.status) AS json_agg,
            35 AS id_enterprise,
            json_agg(d.ocorrencia) AS ocorrencias,
            json_agg(d.status_since) AS last_status_since_array
           FROM ( SELECT c.dispositivo,
                    c.status,
                    c.hora,
                    c.ocorrencia,
                    gapfill(c.status_since) OVER (PARTITION BY c.dispositivo ORDER BY c.hora) AS status_since
                   FROM ( SELECT c35_dashboard_timeline_24h.dispositivo,
                            c35_dashboard_timeline_24h.status,
                            c35_dashboard_timeline_24h.ocorrencia,
                            c35_dashboard_timeline_24h.hora,
                                CASE
                                    WHEN c35_dashboard_timeline_24h.status::text = lead(c35_dashboard_timeline_24h.status) OVER (PARTITION BY c35_dashboard_timeline_24h.dispositivo ORDER BY c35_dashboard_timeline_24h.hora DESC)::text THEN NULL::timestamp with time zone
                                    ELSE c35_dashboard_timeline_24h.hora
                                END AS status_since
                           FROM c35_dashboard_timeline_24h
                          WHERE c35_dashboard_timeline_24h.hora >= (now() - '24:00:00'::interval)
                          ORDER BY c35_dashboard_timeline_24h.dispositivo, c35_dashboard_timeline_24h.hora) c) d
          GROUP BY d.dispositivo
          ORDER BY d.dispositivo) e;
;
-- ===VIEW=== c35_v_shifts_data
CREATE VIEW public.c35_v_shifts_data AS
 SELECT dat.nm_equipment,
    dat.turno,
    dat.dia,
    dat.tipodispositivo,
    dat.id_enterprise,
    dat.qtdproduzida,
    dat.qtdperda,
    dat.rank_shift,
    dat.speed,
    dat.qtdmetaturno,
    dat.velmetaturno,
    dat.qtdperdakg,
    dat.oee,
    dat.oee_area
   FROM (( SELECT eq.id_equipment,
            eq.nm_equipment
           FROM equipments eq
          WHERE eq.id_enterprise = 35) e2
     LEFT JOIN ( SELECT c35_dashboard_producao_24h.turno,
            c35_dashboard_producao_24h.dia,
            c35_dashboard_producao_24h.dispositivo,
            c35_dashboard_producao_24h.tipodispositivo,
            c35_dashboard_producao_24h.id_enterprise,
            COALESCE(sum(c35_dashboard_producao_24h.qtdproduzida) FILTER (WHERE c35_dashboard_producao_24h.dispositivo::text <> 'Rotomec 02'::text), 0::double precision) + COALESCE(sum(c35_dashboard_producao_24h.qtdproduzidaiot) FILTER (WHERE c35_dashboard_producao_24h.dispositivo::text = 'Rotomec 02'::text), 0::double precision) AS qtdproduzida,
            max(c35_dashboard_producao_24h.qtdmetaturno) AS qtdmetaturno,
            max(c35_dashboard_producao_24h.velmetaturno) AS velmetaturno,
            sum(c35_dashboard_producao_24h.qtdperda) AS qtdperda,
            sum(c35_dashboard_producao_24h.qtdperdakg) AS qtdperdakg,
            avg(c35_dashboard_producao_24h.oee) AS oee,
            avg(c35_dashboard_producao_24h.oee_area) AS oee_area,
            rank() OVER (PARTITION BY c35_dashboard_producao_24h.dispositivo ORDER BY c35_dashboard_producao_24h.dia DESC, c35_dashboard_producao_24h.diaanterior DESC, c35_dashboard_producao_24h.turno DESC) AS rank_shift
           FROM c35_dashboard_producao_24h
          WHERE c35_dashboard_producao_24h.dia >= (now() - '2 days'::interval)
          GROUP BY c35_dashboard_producao_24h.turno, c35_dashboard_producao_24h.dia, c35_dashboard_producao_24h.diaanterior, c35_dashboard_producao_24h.dispositivo, c35_dashboard_producao_24h.tipodispositivo, c35_dashboard_producao_24h.id_enterprise, c35_dashboard_producao_24h.oee, c35_dashboard_producao_24h.oee_area
          ORDER BY c35_dashboard_producao_24h.dispositivo, c35_dashboard_producao_24h.dia DESC, c35_dashboard_producao_24h.turno DESC) cdp ON e2.nm_equipment::text = cdp.dispositivo::text
     LEFT JOIN ( SELECT hist.varvalue AS speed,
            hist.dispositivo
           FROM ( SELECT cdth.dispositivo,
                    cdth.varvalue,
                    rank() OVER (PARTITION BY cdth.dispositivo ORDER BY cdth.hora DESC) AS rank_hour
                   FROM c35_dashboard_timeline_24h cdth) hist
          WHERE hist.rank_hour = 1) cdt ON cdp.dispositivo::text = cdt.dispositivo::text) dat(id_equipment, nm_equipment, turno, dia, dispositivo, tipodispositivo, id_enterprise, qtdproduzida, qtdmetaturno, velmetaturno, qtdperda, qtdperdakg, oee, oee_area, rank_shift, speed, dispositivo_1);
;
-- ===VIEW=== c35_v_stopped_time
CREATE VIEW public.c35_v_stopped_time AS
 SELECT eq.nm_equipment,
    aa.dispositivo,
    aa.id_enterprise,
    aa.planned_percent,
    aa.unplanned_percent,
    aa.planned_duration,
    aa.unplanned_duration
   FROM ( SELECT e2.nm_equipment
           FROM equipments e2
          WHERE e2.id_enterprise = 35) eq
     LEFT JOIN ( SELECT c.dispositivo,
            35 AS id_enterprise,
            c.planned_duration / NULLIF(c.total_duration, 0::double precision) AS planned_percent,
            c.unplanned_duration / NULLIF(c.total_duration, 0::double precision) AS unplanned_percent,
            c.planned_duration,
            c.unplanned_duration
           FROM ( SELECT cdph.dispositivo,
                    COALESCE(sum(
                        CASE
                            WHEN cdph.planejada = 1 THEN cdph.duracao
                            ELSE NULL::real
                        END)::double precision, 0::double precision) AS planned_duration,
                    COALESCE(sum(
                        CASE
                            WHEN cdph.planejada = 0 THEN cdph.duracao
                            ELSE NULL::real
                        END)::double precision, 0::double precision) AS unplanned_duration,
                    COALESCE(sum(cdph.duracao), 0::real) AS total_duration
                   FROM c35_dashboard_paradas_24h cdph
                  GROUP BY cdph.dispositivo
                  ORDER BY cdph.dispositivo) c
          GROUP BY c.dispositivo, c.planned_duration, c.unplanned_duration, (c.planned_duration / NULLIF(c.total_duration, 0::double precision)), (c.unplanned_duration / NULLIF(c.total_duration, 0::double precision))
          ORDER BY c.dispositivo) aa ON eq.nm_equipment::text = aa.dispositivo::text;
;
-- ===VIEW=== v13_mobile_power_bi_direct_query
CREATE VIEW public.v13_mobile_power_bi_direct_query AS
 WITH eventos AS (
         SELECT equipment_events.id_equipment,
            equipment_events.status,
            equipment_events.cd_machine,
            equipment_events.cd_category,
            date_part('epoch'::text, now() - equipment_events.ts_event)::integer AS duration_in_seconds,
            equipment_events.txt_downtime_notes
           FROM equipment_events
          WHERE equipment_events.ts_end IS NULL AND (equipment_events.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_site = 13 AND equipments.tp_equipment = 3))
        ), final AS (
         SELECT eq.cd_equipment,
            ev.id_equipment,
            ev.status,
            vt.avg_speed,
            ev.duration_in_seconds,
                CASE
                    WHEN ev.duration_in_seconds < 86400 THEN round(ev.duration_in_seconds::numeric / 3600.0, 1) || 'h'::text
                    ELSE round(ev.duration_in_seconds::numeric / 86400.0, 1) || 'd'::text
                END AS duration,
            ev.cd_machine,
            ev.cd_category,
            vs.gross,
            vs.net,
            vs.scrap,
            vs.scrap_rate,
            ev.txt_downtime_notes,
            po.id_order
           FROM eventos ev
             JOIN equipments eq ON eq.id_equipment = ev.id_equipment AND eq.id_enterprise = 13
             LEFT JOIN v_13_overview_partial_scrap_rate vs ON vs.id_equipment = ev.id_equipment
             LEFT JOIN v_13_overview_takt vt ON vt.id_equipment = ev.id_equipment
             LEFT JOIN production_orders po ON po.id_equipment = ev.id_equipment AND po.id_site = 13 AND po.status = 2 AND po.id_enterprise = 13 AND po.ts_start >= (now() - '14 days'::interval)
        )
 SELECT final.cd_equipment,
    final.id_equipment,
    final.status,
        CASE
            WHEN final.status = 6 THEN concat(final.avg_speed, '/min')
            ELSE final.duration
        END AS curr_info,
    final.avg_speed,
    final.duration_in_seconds,
    final.duration,
    final.cd_machine,
    final.cd_category,
    final.gross,
    final.net,
    final.scrap,
    final.scrap_rate / 100::numeric AS scrap_rate,
    final.txt_downtime_notes,
    final.id_order,
    to_char(timezone('Europe/Zurich'::text, now()), 'Dy, DD.MM.YYYY HH24:MI'::text) AS last_update
   FROM final;
;
-- ===VIEW=== v_13_dt5min_piot4
CREATE VIEW public.v_13_dt5min_piot4 AS
 WITH top_level AS (
         SELECT jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE equipments.id_equipment = 645
        ), category_level AS (
         SELECT jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'position'::text AS "position",
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description
           FROM top_level
        ), downtime_codes1 AS (
         SELECT DISTINCT category_level."position"::integer AS "position",
            category_level.description
           FROM category_level
          ORDER BY (category_level."position"::integer)
        ), downtime_codes AS (
         SELECT
                CASE
                    WHEN downtime_codes1.description = 'Innen-Schweissb'::text THEN 50
                    ELSE downtime_codes1."position"
                END AS "position",
            downtime_codes1.description
           FROM downtime_codes1
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.txt_downtime_notes,
            ee.status,
            dc."position" AS downtimereason,
            ee.cd_machine,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 13
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '15 days'::interval) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3))
        UNION ALL
         SELECT ee.ts_event,
            ee.id_equipment,
            concat('(ManualStop)_', ee.txt_downtime_notes) AS txt_downtime_notes,
            ee.status,
            dc."position" AS downtimereason,
            ee.cd_machine,
            e.cd_equipment,
            ee.ts_event AS nextts,
            '00:10:00'::interval AS duration
           FROM equipment_events_man ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 13
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.ts_event >= (now() - '15 days'::interval) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3))
        ), stops_final AS (
         SELECT concat(date_part('year'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, date_part('month'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, date_part('day'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, 'h', date_part('hour'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, 'm', date_part('minute'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, sb.cd_equipment) AS index_event,
            sb.status,
            sb.cd_equipment,
            sb.ts_event,
            sb.nextts,
            sb.duration,
            sb.downtimereason,
            sb.txt_downtime_notes,
            sb.cd_machine AS nm_equipment_type
           FROM stops_neopac_ch sb
          ORDER BY sb.cd_equipment, sb.ts_event
        )
 SELECT stops_final.index_event,
    stops_final.cd_equipment,
    timezone('Europe/Zurich'::text, stops_final.ts_event) AS ts_event,
    timezone('Europe/Zurich'::text, stops_final.nextts) AS nextts,
        CASE
            WHEN "left"(stops_final.txt_downtime_notes::text, 12) = '(ManualStop)'::text THEN '00:00:00'::interval
            ELSE stops_final.duration
        END AS duration,
    COALESCE(stops_final.downtimereason, 0) AS downtimereason,
    stops_final.txt_downtime_notes,
    stops_final.nm_equipment_type,
    13 AS id_enterprise
   FROM stops_final
  WHERE stops_final.duration > '00:05:00'::interval
  ORDER BY stops_final.cd_equipment, (timezone('Europe/Zurich'::text, stops_final.ts_event));
;
-- ===VIEW=== v_13_labels_piot4
CREATE VIEW public.v_13_labels_piot4 AS
 SELECT sap_report_data_sync_customer_13.linie,
    sap_report_data_sync_customer_13.tag,
    sap_report_data_sync_customer_13.shicht,
    sap_report_data_sync_customer_13.shicht_nummer,
    sap_report_data_sync_customer_13.auftrag,
    sap_report_data_sync_customer_13.sum_labels,
    sap_report_data_sync_customer_13.rumpfe,
    sap_report_data_sync_customer_13.gutmenge,
    sap_report_data_sync_customer_13.shift_start_time,
    sap_report_data_sync_customer_13.auftrag_startzeit,
    sap_report_data_sync_customer_13.data_type,
    sap_report_data_sync_customer_13.id_order_label,
    13 AS id_enterprise
   FROM sap_report_data_sync_customer_13
  WHERE sap_report_data_sync_customer_13.tag >= (now() - '10 days'::interval)
  ORDER BY sap_report_data_sync_customer_13.linie, sap_report_data_sync_customer_13.tag, sap_report_data_sync_customer_13.shicht_nummer, sap_report_data_sync_customer_13.auftrag_startzeit;
;
-- ===VIEW=== v_13_microstops_piot
CREATE VIEW public.v_13_microstops_piot AS
 WITH stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3
          WHERE ee.ts_event >= (now() - '10 days'::interval) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13 AND equipments.tp_equipment = 3)) AND ee.status = 10
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops2 AS (
         SELECT stops_neopac_ch.cd_equipment,
            date(timezone('Europe/Zurich'::text, stops_neopac_ch.ts_event) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, stops_neopac_ch.ts_event)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, stops_neopac_ch.ts_event)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, stops_neopac_ch.ts_event)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, stops_neopac_ch.ts_event)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            stops_neopac_ch.duration
           FROM stops_neopac_ch
          WHERE stops_neopac_ch.status = 10 AND stops_neopac_ch.duration <= '00:05:00'::interval
          ORDER BY stops_neopac_ch.cd_equipment, stops_neopac_ch.ts_event
        )
 SELECT concat(stops2.dia, stops2.cd_equipment, stops2.turno) AS index,
    stops2.cd_equipment,
    stops2.turno,
    date_part('hour'::text, sum(stops2.duration)) * 60::double precision * 60::double precision + date_part('minutes'::text, sum(stops2.duration)) * 60::double precision + date_part('seconds'::text, sum(stops2.duration)) AS tot_duration,
    13 AS id_enterprise
   FROM stops2
  GROUP BY (concat(stops2.dia, stops2.cd_equipment, stops2.turno)), stops2.cd_equipment, stops2.dia, stops2.turno
  ORDER BY stops2.cd_equipment, stops2.dia, stops2.turno;
;
-- ===VIEW=== v_13_overview_partial_scrap_rate
CREATE VIEW public.v_13_overview_partial_scrap_rate AS
 WITH current_shift AS (
         SELECT equipment_runtime_shift.ts_value AS start_current_shift,
            equipment_runtime_shift.id_shift,
            equipment_runtime_shift.id_equipment
           FROM equipment_runtime_shift
          WHERE (equipment_runtime_shift.id_equipment = ANY (ARRAY[645, 770, 729])) AND equipment_runtime_shift.ts_value >= (now() - '13:00:00'::interval) AND equipment_runtime_shift.ts_value < now() AND now() >= equipment_runtime_shift.ts_value AND now() <= equipment_runtime_shift.ts_end
          ORDER BY equipment_runtime_shift.ts_value DESC
        ), data AS (
         SELECT aevmt.id_shift,
            aevmt.id_equipment,
            eq_1.tp_equipment,
                CASE
                    WHEN eq_1.id_parentequipment IS NULL THEN eq_1.id_equipment
                    ELSE eq_1.id_parentequipment
                END AS id_parentequipment,
            sum(aevmt.gross_production_incr) AS gross,
            sum(aevmt.net_production_incr) AS net,
            sum(aevmt.gross_production_incr) - sum(aevmt.net_production_incr) AS dif
           FROM agg_equipment_values_1min_t aevmt
             LEFT JOIN equipments eq_1 ON eq_1.id_equipment = aevmt.id_equipment AND eq_1.id_enterprise = 13
          WHERE aevmt.ts_value >= (now() - '12:00:00'::interval) AND (aevmt.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND (equipments.tp_equipment = ANY (ARRAY[1, 3])) AND (equipments.id_equipment <> ALL (ARRAY[585, 649, 698])))) AND (aevmt.id_shift IN ( SELECT current_shift.id_shift
                   FROM current_shift))
          GROUP BY aevmt.id_equipment, aevmt.id_shift, eq_1.id_parentequipment, eq_1.tp_equipment, eq_1.id_equipment
          ORDER BY eq_1.id_parentequipment
        ), data2 AS (
         SELECT data.tp_equipment,
            data.id_parentequipment,
            sum(data.gross) AS gross,
            sum(data.net) AS net,
            sum(data.dif) AS dif
           FROM data
          GROUP BY data.tp_equipment, data.id_parentequipment
          ORDER BY data.id_parentequipment, data.tp_equipment
        ), data3 AS (
         SELECT data2.id_parentequipment,
            sum(
                CASE
                    WHEN data2.tp_equipment = 1 THEN data2.gross
                    ELSE NULL::double precision
                END) AS gross,
            sum(
                CASE
                    WHEN data2.tp_equipment = 1 THEN data2.net
                    ELSE NULL::double precision
                END) AS net,
            sum(
                CASE
                    WHEN data2.tp_equipment = 1 THEN data2.dif
                    ELSE NULL::double precision
                END) AS dif,
            sum(
                CASE
                    WHEN data2.tp_equipment = 3 THEN data2.net
                    ELSE NULL::double precision
                END) AS net_line
           FROM data2
          GROUP BY data2.id_parentequipment
        )
 SELECT eq.cd_equipment,
    eq.id_enterprise,
    eq.id_site,
    dt.id_parentequipment AS id_equipment,
    dt.gross,
    dt.net,
    dt.dif AS scrap,
        CASE
            WHEN (dt.dif / NULLIF(dt.dif + dt.net_line, 0::double precision)) < 0::double precision THEN 0::numeric
            ELSE (100::double precision * (dt.dif / NULLIF(dt.dif + dt.net_line, 0::double precision)))::numeric(10,4)
        END AS scrap_rate
   FROM data3 dt
     LEFT JOIN equipments eq ON dt.id_parentequipment = eq.id_equipment
  ORDER BY eq.cd_equipment;
;
-- ===VIEW=== v_13_overview_takt
CREATE VIEW public.v_13_overview_takt AS
 WITH lines AS (
         SELECT eq.id_equipment,
            eq.id_parentequipment,
            eq.id_enterprise,
            eq.id_site,
            eq2.production_speed,
            eq2.cd_equipment
           FROM equipments eq
             LEFT JOIN equipments eq2 ON eq.id_parentequipment = eq2.id_equipment AND eq2.id_enterprise = 13
          WHERE eq.id_enterprise = 13 AND (eq.id_parentequipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3)) AND eq.cd_equipment::text ~~ '%Offset%'::text OR eq.cd_equipment::text ~~ '%Printer%'::text
        )
 SELECT l.id_parentequipment AS id_equipment,
    l.id_enterprise,
    l.id_site,
    COALESCE(avg(
        CASE

            WHEN aevmt.gross_production_incr >= (0.5 * l.production_speed::numeric)::double precision THEN aevmt.gross_production_incr
            ELSE NULL::double precision
        END), 0::double precision)::integer AS avg_speed
   FROM agg_equipment_values_1min_t aevmt
     LEFT JOIN lines l ON l.id_equipment = aevmt.id_equipment
  WHERE (aevmt.id_equipment IN ( SELECT lines.id_equipment
           FROM lines)) AND aevmt.id_enterprise = 13 AND aevmt.ts_value >= (now() - '00:11:00'::interval) AND aevmt.ts_value < date_trunc('minute'::text, now())
  GROUP BY l.id_parentequipment, l.id_enterprise, l.id_site;
;
-- ===VIEW=== v_13_pos_piot4
CREATE VIEW public.v_13_pos_piot4 AS
 WITH data AS (
         SELECT date_trunc('minute'::text, agg_equipment_values_1min_t.ts_value) AS ts_hour,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 656 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 673 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 652 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 655 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 675 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 678 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 675 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 678 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 688 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 692 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 694 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 697 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 581 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 584 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 646 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS g117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 650 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS n117
           FROM agg_equipment_values_1min_t
          WHERE agg_equipment_values_1min_t.ts_value >= (now() - '10 days'::interval) AND (agg_equipment_values_1min_t.id_equipment = ANY (ARRAY[656, 673, 652, 655, 675, 678, 688, 692, 694, 697, 581, 584, 646, 650]))
          GROUP BY (date_trunc('minute'::text, agg_equipment_values_1min_t.ts_value))
        ), products AS (
         SELECT production_orders.id_equipment,
            production_orders.status,
            production_orders.id_order,
            production_orders.ts_start,
                CASE
                    WHEN production_orders.status = 2 THEN now()
                    WHEN production_orders.status >= 3 AND production_orders.ts_end IS NULL THEN production_orders.ts_start
                    ELSE production_orders.ts_end
                END AS ts_end
           FROM production_orders
          WHERE production_orders.id_enterprise = 13 AND production_orders.ts_start >= (now() - '10 days'::interval) AND production_orders.status > 1
          ORDER BY production_orders.id_equipment, production_orders.ts_start
        ), line101 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g101,
            dt.n101,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 183
          ORDER BY dt.ts_hour
        ), line102 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g102,
            dt.n102,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 651
          ORDER BY dt.ts_hour
        ), line103 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g103,
            dt.n103,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 674
          ORDER BY dt.ts_hour
        ), line112 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g112,
            dt.n112,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 674
          ORDER BY dt.ts_hour
        ), line114 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g114,
            dt.n114,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 687
          ORDER BY dt.ts_hour
        ), line115 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g115,
            dt.n115,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 693
          ORDER BY dt.ts_hour
        ), line116 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g116,
            dt.n116,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 586
          ORDER BY dt.ts_hour
        ), line117 AS (
         SELECT timezone('Europe/Zurich'::text, dt.ts_hour) AS minuto,
            date(timezone('Europe/Zurich'::text, dt.ts_hour) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 6::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 13::double precision THEN 'T1'::text
                    WHEN date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) >= 14::double precision AND date_part('hour'::text, timezone('Europe/Zurich'::text, dt.ts_hour)) <= 21::double precision THEN 'T2'::text
                    ELSE 'T3'::text
                END AS turno,
            pro.id_equipment,
            dt.g117,
            dt.n117,
            pro.id_order,
            pro.ts_start
           FROM data dt
             LEFT JOIN products pro ON timezone('Europe/Zurich'::text, dt.ts_hour) >= timezone('Europe/Zurich'::text, pro.ts_start) AND timezone('Europe/Zurich'::text, dt.ts_hour) < timezone('Europe/Zurich'::text, pro.ts_end) AND pro.id_equipment = 645
          ORDER BY dt.ts_hour
        ), final AS (
         SELECT line101.dia,
            line101.turno,
            'TL101'::text AS line,
            line101.id_equipment,
            sum(line101.g101) AS gross,
            sum(line101.n101) AS net,
            line101.id_order,
            line101.ts_start
           FROM line101
          GROUP BY line101.dia, line101.turno, line101.id_equipment, line101.id_order, line101.ts_start
        UNION ALL
         SELECT line102.dia,
            line102.turno,
            'TL102'::text AS line,
            line102.id_equipment,
            sum(line102.g102) AS gross,
            sum(line102.n102) AS net,
            line102.id_order,
            line102.ts_start
           FROM line102
          GROUP BY line102.dia, line102.turno, line102.id_equipment, line102.id_order, line102.ts_start
        UNION ALL
         SELECT line103.dia,
            line103.turno,
            'TL103'::text AS line,
            line103.id_equipment,
            sum(line103.g103) AS gross,
            sum(line103.n103) AS net,
            line103.id_order,
            line103.ts_start
           FROM line103
          GROUP BY line103.dia, line103.turno, line103.id_equipment, line103.id_order, line103.ts_start
        UNION ALL
         SELECT line112.dia,
            line112.turno,
            'TL112'::text AS line,
            line112.id_equipment,
            sum(line112.g112) AS gross,
            sum(line112.n112) AS net,
            line112.id_order,
            line112.ts_start
           FROM line112
          GROUP BY line112.dia, line112.turno, line112.id_equipment, line112.id_order, line112.ts_start
        UNION ALL
         SELECT line114.dia,
            line114.turno,
            'TL114'::text AS line,
            line114.id_equipment,
            sum(line114.g114) AS gross,
            sum(line114.n114) AS net,
            line114.id_order,
            line114.ts_start
           FROM line114
          GROUP BY line114.dia, line114.turno, line114.id_equipment, line114.id_order, line114.ts_start
        UNION ALL
         SELECT line115.dia,
            line115.turno,
            'TL115'::text AS line,
            line115.id_equipment,
            sum(line115.g115) AS gross,
            sum(line115.n115) AS net,
            line115.id_order,
            line115.ts_start
           FROM line115
          GROUP BY line115.dia, line115.turno, line115.id_equipment, line115.id_order, line115.ts_start
        UNION ALL
         SELECT line116.dia,
            line116.turno,
            'TL116'::text AS line,
            line116.id_equipment,
            sum(line116.g116) AS gross,
            sum(line116.n116) AS net,
            line116.id_order,
            line116.ts_start
           FROM line116
          GROUP BY line116.dia, line116.turno, line116.id_equipment, line116.id_order, line116.ts_start
        UNION ALL
         SELECT line117.dia,
            line117.turno,
            'TL117'::text AS line,
            line117.id_equipment,
            sum(line117.g117) AS gross,
            sum(line117.n117) AS net,
            line117.id_order,
            line117.ts_start
           FROM line117
          GROUP BY line117.dia, line117.turno, line117.id_equipment, line117.id_order, line117.ts_start
  ORDER BY 4, 1, 2, 8
        ), final2 AS (
         SELECT final.dia,
            final.turno,
            final.line,
            final.id_equipment,
            final.gross,
            final.net,
            final.id_order,
            final.ts_start,
            concat(final.dia, final.line, final.turno) AS index
           FROM final
          WHERE final.id_equipment IS NOT NULL
          ORDER BY final.id_equipment, final.dia, final.turno, final.ts_start
        ), prod_orders_final AS (
         SELECT concat(final2.index, rank() OVER (PARTITION BY final2.index ORDER BY final2.id_equipment, final2.dia, final2.turno, final2.ts_start)) AS prod_index,
            final2.line,
            final2.dia,
            final2.turno,
            final2.gross,
            final2.net,
            final2.id_order,
            timezone('Europe/Zurich'::text, final2.ts_start) AS ts_start,
            13 AS id_enterprise
           FROM final2
          ORDER BY final2.line, final2.dia, final2.turno, (timezone('Europe/Zurich'::text, final2.ts_start))
        ), labels AS (
         SELECT lb.linie,
            lb.tag,
            concat('T', lb.shicht_nummer) AS shicht,
            lb.auftrag,
            sum(COALESCE(lb.sum_labels, 0::bigint)) AS labels_final
           FROM v_13_labels_piot4 lb
          GROUP BY lb.linie, lb.tag, (concat('T', lb.shicht_nummer)), lb.auftrag
          ORDER BY lb.linie, lb.tag, (concat('T', lb.shicht_nummer))
        )
 SELECT po.prod_index,
    po.line,
    po.turno,
    po.gross,
    l.labels_final::double precision AS net,
    po.id_order,
    po.ts_start,
    po.id_enterprise
   FROM prod_orders_final po
     LEFT JOIN labels l ON l.linie::text = po.line AND l.shicht = po.turno AND l.auftrag = po.id_order AND l.tag = "left"(po.prod_index, 10)::date
  ORDER BY po.line, po.dia, po.turno, (timezone('Europe/Zurich'::text, po.ts_start));
;
-- ===VIEW=== v_13_production2_piot4
CREATE VIEW public.v_13_production2_piot4 AS
 WITH data_neopac_ch AS (
         SELECT date_trunc('HOUR'::text, agg_equipment_values_1min_t.ts_value) AS ts_hour,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 656 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 656 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s2_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 671 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 671 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s4_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 672 THEN agg_equipment_values_1min_t.gross_production_incr

                    ELSE NULL::numeric::double precision
                END) AS s5_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 672 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s6_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 673 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 673 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s8_101,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 652 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 652 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s2_102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 653 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 653 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s5_102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 654 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s6_102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 654 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 655 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s8_102,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 675 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 410 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s2_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 675 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 676 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s5_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 676 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 677 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s9_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 677 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s11_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 678 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s13_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 678 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s15_103,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 418 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 419 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s2_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 420 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 421 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s4_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 422 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s5_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 423 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s6_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 424 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 425 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s8_112,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 688 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 655 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s2_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 688 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 690 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s5_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 689 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s6_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 690 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 689 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s8_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 691 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s9_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 691 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s11_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 692 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s13_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 692 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s15_114,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 694 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 192 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s2_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 694 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 695 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s5_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 695 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 696 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s9_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 696 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s11_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 697 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s13_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 698 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s15_115,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 581 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 581 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 582 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s5_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 582 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 583 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s9_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 583 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s11_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 584 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s13_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 584 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s15_116,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 646 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s1_117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 646 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s3_117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 647 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s4_117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 647 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s5_117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 648 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s6_117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 649 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s7_117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 650 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s8_117,
            sum(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 650 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END) AS s9_117,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 75::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 656 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS ss_101,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 75::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 671 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS nh_101,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 75::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 672 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS off_101,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 75::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 673 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rhm_101,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.net_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 673 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS pac_101,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 75::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 652 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double p--output truncated--
                    ELSE NULL::numeric::double precision
                END)) AS nh_112,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 40::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 421 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS off_112,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 40::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 424 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rhm_112,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 425 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS pac_112,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 50::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 688 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rs_114,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 50::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 690 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS nh_114,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 50::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 691 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS off_114,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 50::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 692 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rhm_114,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.net_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 692 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS pac_114,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 40::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 694 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS ss_115,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 40::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 695 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS nh_115,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 40::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 696 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS off_115,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 40::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 697 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rhm_115,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 698 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS pac_115,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 581 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS ss_116,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 582 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS nh_116,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 583 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS off_116,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 584 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rhm_116,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 585 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS pac_116,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 646 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rs_117,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 647 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS nh_117,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 648 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS off_117,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.gross_production_incr > 60::numeric::double precision AND agg_equipment_values_1min_t.gross_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 650 THEN agg_equipment_values_1min_t.gross_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS rhm_117,
            round(avg(
                CASE
                    WHEN agg_equipment_values_1min_t.net_production_incr >= 0::numeric::double precision AND agg_equipment_values_1min_t.net_production_incr < 300::numeric::double precision AND agg_equipment_values_1min_t.id_equipment = 650 THEN agg_equipment_values_1min_t.net_production_incr
                    ELSE NULL::numeric::double precision
                END)) AS pac_117
           FROM agg_equipment_values_1min_t
          WHERE agg_equipment_values_1min_t.ts_value >= (now() - '10 days'::interval) AND (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 13))
          GROUP BY (date_trunc('HOUR'::text, agg_equipment_values_1min_t.ts_value))
        )
 SELECT timezone('Europe/Zurich'::text, data_neopac_ch.ts_hour) AS ts_hour_tz,
    concat(date_part('year'::text, timezone('Europe/Zurich'::text, data_neopac_ch.ts_hour))::text, date_part('month'::text, timezone('Europe/Zurich'::text, data_neopac_ch.ts_hour))::text, date_part('day'::text, timezone('Europe/Zurich'::text, data_neopac_ch.ts_hour))::text, 'h', date_part('hour'::text, timezone('Europe/Zurich'::text, data_neopac_ch.ts_hour))::text, 'm', date_part('minute'::text, timezone('Europe/Zurich'::text, data_neopac_ch.ts_hour))::text) AS time_index,
    data_neopac_ch.s1_101,
    data_neopac_ch.s2_101,
    data_neopac_ch.s3_101,
    data_neopac_ch.s4_101,
    data_neopac_ch.s5_101,
    data_neopac_ch.s6_101,
    data_neopac_ch.s7_101,
    data_neopac_ch.s8_101,
    data_neopac_ch.ss_101,
    data_neopac_ch.nh_101,
    data_neopac_ch.off_101,
    data_neopac_ch.rhm_101,
    data_neopac_ch.s1_102,
    data_neopac_ch.s2_102,
    data_neopac_ch.s3_102,
    data_neopac_ch.s5_102,
    data_neopac_ch.s6_102,
    data_neopac_ch.s7_102,
    data_neopac_ch.s8_102,
    data_neopac_ch.ss_102,
    data_neopac_ch.nh_102,
    data_neopac_ch.off_102,
    data_neopac_ch.rhm_102,
    data_neopac_ch.s1_103,
    data_neopac_ch.s2_103,
    data_neopac_ch.s3_103,
    data_neopac_ch.s5_103,
    data_neopac_ch.s7_103,
    data_neopac_ch.s9_103,
    data_neopac_ch.s11_103,
    data_neopac_ch.s13_103,
    data_neopac_ch.s15_103,
    data_neopac_ch.ss_103,
    data_neopac_ch.nh_103,
    data_neopac_ch.off_103,
    data_neopac_ch.rhm_103,
    data_neopac_ch.s1_112,
    data_neopac_ch.s2_112,
    data_neopac_ch.s3_112,
    data_neopac_ch.s4_112,
    data_neopac_ch.s5_112,
    data_neopac_ch.s6_112,
    data_neopac_ch.s7_112,
    data_neopac_ch.s8_112,
    data_neopac_ch.ss_112,
    data_neopac_ch.nh_112,
    data_neopac_ch.off_112,
    data_neopac_ch.rhm_112,
    data_neopac_ch.s1_114,
    data_neopac_ch.s2_114,
    data_neopac_ch.s3_114,
    data_neopac_ch.s5_114,
    data_neopac_ch.s6_114,
    data_neopac_ch.s7_114,
    data_neopac_ch.s8_114,
    data_neopac_ch.s9_114,
    data_neopac_ch.s11_114,
    data_neopac_ch.s13_114,
    data_neopac_ch.s15_114,
    data_neopac_ch.rs_114,
    data_neopac_ch.nh_114,
    data_neopac_ch.off_114,
    data_neopac_ch.rhm_114,
    data_neopac_ch.s1_115,
    data_neopac_ch.s2_115,
    data_neopac_ch.s3_115,
    data_neopac_ch.s5_115,
    data_neopac_ch.s7_115,
    data_neopac_ch.s9_115,
    data_neopac_ch.s11_115,
    data_neopac_ch.s13_115,
    data_neopac_ch.s15_115,
    data_neopac_ch.ss_115,
    data_neopac_ch.nh_115,
    data_neopac_ch.off_115,
    data_neopac_ch.rhm_115,
    data_neopac_ch.s1_116,
    data_neopac_ch.s3_116,
    data_neopac_ch.s5_116,
    data_neopac_ch.s7_116,
    data_neopac_ch.s9_116,
    data_neopac_ch.s11_116,
    data_neopac_ch.s13_116,
    data_neopac_ch.s15_116,
    data_neopac_ch.ss_116,
    data_neopac_ch.nh_116,
    data_neopac_ch.off_116,
    data_neopac_ch.rhm_116,
    data_neopac_ch.s1_117,
    data_neopac_ch.s3_117,
    data_neopac_ch.s4_117,
    data_neopac_ch.s5_117,
    data_neopac_ch.s6_117,
    data_neopac_ch.s7_117,
    data_neopac_ch.s8_117,
    data_neopac_ch.s9_117,
    data_neopac_ch.rs_117,
    data_neopac_ch.nh_117,
    data_neopac_ch.off_117,
    data_neopac_ch.rhm_117,
    timezone('Europe/Zurich'::text, now()) AS refresh_time,
    data_neopac_ch.pac_101,
    data_neopac_ch.pac_102,
    data_neopac_ch.pac_103,
    data_neopac_ch.pac_112,
    data_neopac_ch.pac_114,
    data_neopac_ch.pac_115,
    data_neopac_ch.pac_116,
    data_neopac_ch.pac_117,
    13 AS id_enterprise
   FROM data_neopac_ch
  ORDER BY data_neopac_ch.ts_hour;
;
-- ===VIEW=== v_13_site_deb_dt5min_piot4
CREATE VIEW public.v_13_site_deb_dt5min_piot4 AS
 WITH top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29)) AND (equipments.id_equipment <> ALL (ARRAY[708, 831, 833, 835]))
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
            ee.txt_downtime_notes,
            ee.status,
            dc."position" AS downtimereason,
            ee.cd_machine,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '15 days'::interval) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3 AND (equipments.id_equipment <> ALL (ARRAY[708, 831, 833, 835]))))
        UNION ALL
         SELECT ee.ts_event,
            ee.id_equipment,
            concat('(ManualStop)_', ee.txt_downtime_notes) AS txt_downtime_notes,
            ee.status,
            dc."position" AS downtimereason,
            ee.cd_machine,
            e.cd_equipment,
            ee.ts_event AS nextts,
            '00:10:00'::interval AS duration
           FROM equipment_events_man ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.ts_event >= (now() - '15 days'::interval) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3 AND (equipments.id_equipment <> ALL (ARRAY[708, 831, 833, 835]))))
        ), stops_final AS (
         SELECT concat(date_part('year'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, date_part('month'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, date_part('day'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, 'h', date_part('hour'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, 'm', date_part('minute'::text, timezone('Europe/Zurich'::text, sb.ts_event))::text, sb.cd_equipment) AS index_event,
            sb.status,
            sb.cd_equipment,
            sb.ts_event,
            sb.nextts,
            sb.duration,
            sb.downtimereason,
            sb.txt_downtime_notes,
            sb.cd_machine AS nm_equipment_type
           FROM stops_neopac_ch sb
          ORDER BY sb.cd_equipment, sb.ts_event
        )
 SELECT stops_final.index_event,
    stops_final.cd_equipment,
    timezone('Europe/Zurich'::text, stops_final.ts_event) AS ts_event,
    timezone('Europe/Zurich'::text, stops_final.nextts) AS nextts,
        CASE
            WHEN "left"(stops_final.txt_downtime_notes::text, 12) = '(ManualStop)'::text THEN '00:00:00'::interval
            ELSE stops_final.duration
        END AS duration,
    COALESCE(stops_final.downtimereason, 0) AS downtimereason,
    stops_final.txt_downtime_notes,
    stops_final.nm_equipment_type,
    13 AS id_enterprise
   FROM stops_final
  WHERE stops_final.duration > '00:05:00'::interval
  ORDER BY stops_final.cd_equipment, (timezone('Europe/Zurich'::text, stops_final.ts_event));
;
-- ===VIEW=== v_13_site_deb_equipment_list
CREATE VIEW public.v_13_site_deb_equipment_list AS
 WITH parent_list AS (
         SELECT p.id_equipment AS parent_id,
            p.nm_equipment AS prod_line
           FROM equipments p
          WHERE p.id_enterprise = 13 AND p.id_site = 29 AND p.id_area = 58 AND p.tp_equipment = 3
        ), child_list AS (
         SELECT pl.parent_id,
            pl.prod_line,
            e."position",
            e.nm_equipment,
            row_number() OVER (PARTITION BY pl.parent_id ORDER BY e."position") AS rn
           FROM parent_list pl
             JOIN equipments e ON e.id_parentequipment = pl.parent_id
        )
 SELECT 13 AS id_enterprise,
    child_list.prod_line,
    max(
        CASE
            WHEN child_list.rn = 1 THEN child_list.nm_equipment
            ELSE NULL::character varying
        END::text) AS equip1,
    max(
        CASE
            WHEN child_list.rn = 2 THEN child_list.nm_equipment
            ELSE NULL::character varying
        END::text) AS equip2,
    max(
        CASE
            WHEN child_list.rn = 3 THEN child_list.nm_equipment
            ELSE NULL::character varying
        END::text) AS equip3,
    max(
        CASE
            WHEN child_list.rn = 4 THEN child_list.nm_equipment
            ELSE NULL::character varying
        END::text) AS equip4,
    max(
        CASE
            WHEN child_list.rn = 5 THEN child_list.nm_equipment
            ELSE NULL::character varying
        END::text) AS equip5,
    timezone('Europe/Budapest'::text, now()) AS last_update
   FROM child_list
  GROUP BY child_list.prod_line
  ORDER BY child_list.prod_line;
;
-- ===VIEW=== v_13_site_deb_labels_piot4v_13
CREATE VIEW public.v_13_site_deb_labels_piot4v_13 AS
 WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '6 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
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
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29 AND (equipments.id_equipment <> ALL (ARRAY[708, 835, 833, 831])))) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
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
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
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
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '6 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 29
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
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
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
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
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
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= e.stop_threshold_time::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < e.stop_threshold_time::double precision THEN 5
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
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '6 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
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
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '6 days'::interval)
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
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '5 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.shift_start_time::timestamp with time zone AS shift_start_time,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.data_type,
    final11.id_order_label,
    13 AS id_enterprise
   FROM final11;
;
-- ===VIEW=== v_13_site_deb_microstops_piot
CREATE VIEW public.v_13_site_deb_microstops_piot AS
 WITH stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3
          WHERE ee.ts_event >= (now() - '10 days'::interval) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3 AND (equipments.id_equipment <> ALL (ARRAY[708, 835, 833, 831])))) AND ee.status = 10
        ), stops2 AS (
         SELECT s.cd_equipment,
            date(timezone('Europe/Zurich'::text, s.ts_event) - '05:45:00'::interval) AS dia,
                CASE
                    WHEN timezone('Europe/Zurich'::text, s.ts_event)::time without time zone >= '05:45:00'::time without time zone AND timezone('Europe/Zurich'::text, s.ts_event)::time without time zone < '17:45:00'::time without time zone THEN 'T1'::text
                    ELSE 'T2'::text
                END AS turno,
            s.duration
           FROM stops_neopac_ch s
          WHERE s.status = 10 AND s.duration <= '00:05:00'::interval
        )
 SELECT concat(stops2.dia, stops2.cd_equipment, stops2.turno) AS index,
    stops2.cd_equipment,
    stops2.turno,
    date_part('epoch'::text, sum(stops2.duration)) AS tot_duration,
    13 AS id_enterprise
   FROM stops2
  GROUP BY (concat(stops2.dia, stops2.cd_equipment, stops2.turno)), stops2.cd_equipment, stops2.dia, stops2.turno
  ORDER BY stops2.cd_equipment, stops2.dia, stops2.turno;
;
-- ===VIEW=== v_13_site_deb_pos_labels
CREATE VIEW public.v_13_site_deb_pos_labels AS
 WITH dias AS (
         SELECT generate_series(timezone('Europe/Zurich'::text, now())::date - '6 days'::interval, timezone('Europe/Zurich'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Zurich'::text, ers.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Zurich'::text, ers.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
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
           FROM equipment_runtime_shift ers,
            start_counting_day scd,
            shifts shi
          WHERE (ers.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND ers.ts_value_production >= scd.start_day AND ers.ts_value <= now() AND shi.id_shift = ers.id_shift
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
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
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
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '6 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 29
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
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
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
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
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
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= e.stop_threshold_time::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < e.stop_threshold_time::double precision THEN 5
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
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '90 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '6 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
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
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            ppf.shift_start_time,
            timezone('Europe/Zurich'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
        ), labels_data AS (
         SELECT ebc.id_equipment,
            ebc.ts_value,
            ebc.id_order,
            ebc.net_production
           FROM equipment_boxes_cust_13 ebc
          WHERE (ebc.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND ebc.ts_value >= (now() - '6 days'::interval)
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
          WHERE final10.tag >= (timezone('Europe/Zurich'::text, now()) - '5 days'::interval)
        )
 SELECT final11.linie,
    final11.tag,
    final11.shicht,
    final11.shicht_nummer,
    final11.auftrag,
    final11.sum_labels,
    final11.rumpfe,
    final11.gutmenge::double precision AS gutmenge,
    final11.shift_start_time::timestamp with time zone AS shift_start_time,
    final11.auftrag_startzeit::timestamp without time zone AS auftrag_startzeit,
    final11.data_type,
    final11.id_order_label,
    13 AS id_enterprise
   FROM final11
  WHERE (final11.linie::text IN ( SELECT equipments.nm_equipment
           FROM equipments
          WHERE equipments.id_site = 29 AND equipments.id_area = 58 AND equipments.tp_equipment = 3));
;
-- ===VIEW=== v_13_site_deb_pos_piot4
CREATE VIEW public.v_13_site_deb_pos_piot4 AS
 WITH neopac_deb_jobs AS (
         SELECT concat(v_13_site_deb_pos_labels.tag, v_13_site_deb_pos_labels.linie, concat('T', v_13_site_deb_pos_labels.shicht_nummer)) AS index,
            v_13_site_deb_pos_labels.tag,
            v_13_site_deb_pos_labels.linie AS line,
            concat('T', v_13_site_deb_pos_labels.shicht_nummer) AS turno,
            v_13_site_deb_pos_labels.rumpfe AS gross,
            v_13_site_deb_pos_labels.sum_labels AS net,
            v_13_site_deb_pos_labels.auftrag AS id_order,
            v_13_site_deb_pos_labels.auftrag_startzeit AS ts_start,
            13 AS id_enterprise
           FROM v_13_site_deb_pos_labels
        )
 SELECT concat(neopac_deb_jobs.index, rank() OVER (PARTITION BY neopac_deb_jobs.index ORDER BY neopac_deb_jobs.line, neopac_deb_jobs.tag, neopac_deb_jobs.turno, neopac_deb_jobs.ts_start)) AS prod_index,
    neopac_deb_jobs.line,
    neopac_deb_jobs.turno,
    neopac_deb_jobs.gross,
    neopac_deb_jobs.net,
    neopac_deb_jobs.id_order,
    neopac_deb_jobs.ts_start,
    neopac_deb_jobs.id_enterprise
   FROM neopac_deb_jobs
  ORDER BY neopac_deb_jobs.line, neopac_deb_jobs.tag, neopac_deb_jobs.turno, neopac_deb_jobs.ts_start;
;
-- ===VIEW=== v_13_site_deb_prod_per_equipment
CREATE VIEW public.v_13_site_deb_prod_per_equipment AS
 WITH parent_list AS (
         SELECT p.id_equipment AS parent_id,
            p.nm_equipment AS parent_name
           FROM equipments p
          WHERE p.id_enterprise = 13 AND p.id_site = 29 AND p.id_area = 58 AND p.tp_equipment = 3
        ), base_pre AS (
         SELECT timezone('Europe/Budapest'::text, eqv.ts_value) AS ts_budapest,
            eq.id_parentequipment,
            pl.parent_name,
            eq."position" AS original_position,
            eq.nm_equipment,
            eqv.id_equipment,
            eqv.gross_production_incr,
            eqv.net_production_incr
           FROM agg_equipment_values_1min_t eqv
             JOIN equipments eq ON eq.id_equipment = eqv.id_equipment
             JOIN parent_list pl ON pl.parent_id = eq.id_parentequipment
          WHERE eqv.ts_value >= (now() - '7 days'::interval) AND eqv.id_enterprise = 13
        ), base AS (
         SELECT
                CASE
                    WHEN base_pre.ts_budapest::time without time zone < '05:45:00'::time without time zone THEN base_pre.ts_budapest::date - 1
                    ELSE base_pre.ts_budapest::date
                END AS day,
                CASE
                    WHEN base_pre.ts_budapest::time without time zone >= '05:45:00'::time without time zone AND base_pre.ts_budapest::time without time zone < '17:45:00'::time without time zone THEN 1
                    ELSE 2
                END AS shift,
            row_number() OVER (PARTITION BY base_pre.id_parentequipment, (
                CASE
                    WHEN base_pre.ts_budapest::time without time zone < '05:45:00'::time without time zone THEN base_pre.ts_budapest::date - 1
                    ELSE base_pre.ts_budapest::date
                END), (
                CASE
                    WHEN base_pre.ts_budapest::time without time zone >= '05:45:00'::time without time zone AND base_pre.ts_budapest::time without time zone < '17:45:00'::time without time zone THEN 1
                    ELSE 2
                END) ORDER BY base_pre.original_position) AS "position",
            base_pre.id_parentequipment,
            base_pre.parent_name,
            base_pre.nm_equipment,
            base_pre.id_equipment,
            sum(base_pre.gross_production_incr) AS gross,
            sum(base_pre.net_production_incr) AS net
           FROM base_pre
          GROUP BY (
                CASE
                    WHEN base_pre.ts_budapest::time without time zone < '05:45:00'::time without time zone THEN base_pre.ts_budapest::date - 1
                    ELSE base_pre.ts_budapest::date
                END), (
                CASE
                    WHEN base_pre.ts_budapest::time without time zone >= '05:45:00'::time without time zone AND base_pre.ts_budapest::time without time zone < '17:45:00'::time without time zone THEN 1
                    ELSE 2
                END), base_pre.id_parentequipment, base_pre.parent_name, base_pre.original_position, base_pre.nm_equipment, base_pre.id_equipment
        ), unpivoted AS (
         SELECT b.day,
            b.shift,
            b.id_parentequipment,
            b.parent_name,
            b."position",
            v.sensor_pos,
            v.value
           FROM base b
             CROSS JOIN LATERAL ( VALUES (1,b.gross), (2,b.net)) v(sensor_pos, value)
        ), final AS (
         SELECT 13 AS id_enterprise,
            unpivoted.day,
            unpivoted.shift,
            unpivoted.id_parentequipment,
            unpivoted.parent_name,
            max(
                CASE
                    WHEN unpivoted."position" = 1 AND unpivoted.sensor_pos = 1 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos1_1,
            max(
                CASE
                    WHEN unpivoted."position" = 1 AND unpivoted.sensor_pos = 2 THEN unpivoted.value

                    ELSE NULL::double precision
                END) AS pos1_2,
            max(
                CASE
                    WHEN unpivoted."position" = 2 AND unpivoted.sensor_pos = 1 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos2_1,
            max(
                CASE
                    WHEN unpivoted."position" = 2 AND unpivoted.sensor_pos = 2 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos2_2,
            max(
                CASE
                    WHEN unpivoted."position" = 3 AND unpivoted.sensor_pos = 1 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos3_1,
            max(
                CASE
                    WHEN unpivoted."position" = 3 AND unpivoted.sensor_pos = 2 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos3_2,
            max(
                CASE
                    WHEN unpivoted."position" = 4 AND unpivoted.sensor_pos = 1 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos4_1,
            max(
                CASE
                    WHEN unpivoted."position" = 4 AND unpivoted.sensor_pos = 2 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos4_2,
            max(
                CASE
                    WHEN unpivoted."position" = 5 AND unpivoted.sensor_pos = 1 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos5_1,
            max(
                CASE
                    WHEN unpivoted."position" = 5 AND unpivoted.sensor_pos = 2 THEN unpivoted.value
                    ELSE NULL::double precision
                END) AS pos5_2
           FROM unpivoted
          GROUP BY unpivoted.day, unpivoted.shift, unpivoted.id_parentequipment, unpivoted.parent_name
          ORDER BY unpivoted.day, unpivoted.parent_name, unpivoted.shift
        )
 SELECT 13 AS id_enterprise,
    concat(final.parent_name, '_', final.day, '_', final.shift) AS index1,
    final.pos1_1,
    final.pos1_2,
    final.pos2_1,
    final.pos2_2,
    final.pos3_1,
    final.pos3_2,
    final.pos4_1,
    final.pos4_2,
    final.pos5_1,
    final.pos5_2,
    final.day
   FROM final
  WHERE final.day >= (now()::date - '5 days'::interval);
;
-- ===VIEW=== v_13_site_deb_sap_report
CREATE VIEW public.v_13_site_deb_sap_report AS
 WITH dias AS (
         SELECT generate_series(timezone('Europe/Budapest'::text, now())::date - '3 days'::interval, timezone('Europe/Budapest'::text, now())::date::timestamp without time zone, '1 day'::interval)::date AS start_day
        ), start_counting_day AS (
         SELECT min(dias.start_day) AS start_day
           FROM dias
          ORDER BY (min(dias.start_day)) DESC
         LIMIT 1
        ), turnos AS (
         SELECT concat(to_char(timezone('Europe/Budapest'::text, equipment_runtime_shift.ts_value)::time without time zone::interval, 'HH24:MI'::text), '-', to_char(timezone('Europe/Budapest'::text, equipment_runtime_shift.ts_end)::time without time zone::interval, 'HH24:MI'::text)) AS turno_hrs,
            equipment_runtime_shift.ts_value AS shift_start_time,
            equipment_runtime_shift.id_equipment,
            equipment_runtime_shift.cd_shift,
            equipment_runtime_shift.id_shift,
            equipment_runtime_shift.ts_value_production,
            equipment_runtime_shift.ts_value AS tz_value,
                CASE
                    WHEN equipment_runtime_shift.ts_end > now() THEN now()
                    ELSE equipment_runtime_shift.ts_end
                END AS tz_end
           FROM equipment_runtime_shift,
            start_counting_day scd
          WHERE (equipment_runtime_shift.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND equipment_runtime_shift.ts_value_production >= scd.start_day AND equipment_runtime_shift.ts_value < now()
          ORDER BY equipment_runtime_shift.id_equipment, equipment_runtime_shift.ts_value
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
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND (equipments.tp_equipment = ANY (ARRAY[1, 2]))))
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
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.id_site = 29 AND equipments_1.tp_equipment = 3))
  ORDER BY 2
        ), presscount AS (
         SELECT agg_equipment_values_1min_t.id_equipment,
            agg_equipment_values_1min_t.id_site,
            agg_equipment_values_1min_t.id_area,
            agg_equipment_values_1min_t.ts_value AS tz_value,
            agg_equipment_values_1min_t.gross_production_incr,
            agg_equipment_values_1min_t.net_production_incr
           FROM agg_equipment_values_1min_t,
            start_counting_day scd
          WHERE (agg_equipment_values_1min_t.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3)) AND agg_equipment_values_1min_t.ts_value >= (now() - '3 days'::interval) AND agg_equipment_values_1min_t.ts_value >= scd.start_day AND agg_equipment_values_1min_t.id_enterprise = 13 AND agg_equipment_values_1min_t.id_site = 29
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
                    WHEN upper(porun.runtime_timerange) IS NULL THEN now()
                    ELSE upper(porun.runtime_timerange)
                END AS job_end,
            upper(porun.runtime_timerange) AS ts_end_progress
           FROM production_orders_runtime porun,
            production_orders po
          WHERE (porun.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.tp_equipment = 3 AND equipments.id_site = 29)) AND po.id_equipment = porun.id_equipment AND po.id_enterprise = 13 AND po.id_production_order = porun.id_production_order AND lower(porun.runtime_timerange) >= (now() - '90 days'::interval)
          ORDER BY porun.id_equipment, porun.runtime_timerange
        ), negative_labels AS (
         SELECT l.tz_value,
            l.id_equipment,
            l.label_job,
            l.label_amount,
            po.job_end,
                CASE
                    WHEN po.job_end IS NULL THEN 0::bigint
                    ELSE date_part('epoch'::text, l.tz_value - po.job_end)::bigint
                END AS diff_s
           FROM labels_extract l
             LEFT JOIN prod_orders po ON l.label_job::integer = po.id_order
        ), labels AS (
         SELECT DISTINCT negative_labels.tz_value,
            negative_labels.id_equipment,
            negative_labels.label_job,
            negative_labels.label_amount
           FROM negative_labels
          WHERE negative_labels.diff_s <= 10800
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
             LEFT JOIN presscount pc ON pc.tz_value >= bfs.inicio AND pc.tz_value <= bfs.fim AND pc.id_equipment = bfs.id_equipment AND pc.id_site = bfs.id_site AND pc.id_area = bfs.id_area
          GROUP BY bfs.id_equipment, bfs.cd_shift, bfs.ts_value_production, bfs.id_order, bfs.inicio, bfs.fim, bfs.id_shift, bfs.turno_hrs, bfs.shift_start_time
          ORDER BY bfs.id_equipment, bfs.inicio
        ), top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 29))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
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
                    WHEN dc."position" = 24 THEN 1
                    WHEN dc."position" = 2 THEN 2
                    WHEN dc."position" = ANY (ARRAY[5, 8]) THEN 3
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) >= e.stop_threshold_time::double precision THEN 4
                    WHEN dc."position" IS NULL AND date_part('epoch'::text, COALESCE(ee.ts_end, now()) - ee.ts_event) < e.stop_threshold_time::double precision THEN 5
                    ELSE 0
                END AS downtimereason,
            ee.cd_machine,
            ee.cd_category,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration,
            e.stop_threshold_time
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 29
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description AND ee.id_equipment = dc.id_equipment
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '15 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '3 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 29 AND equipments.tp_equipment = 3))
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
                END), 0::double precision) AS dt_5
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
             LEFT JOIN labels l ON l.tz_value >= bfs.inicio AND l.tz_value <= (bfs.fim - '00:00:01'::interval) AND l.id_equipment = bfs.id_equipment
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
            f.dt_5
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
            f.dt_5
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
            ((ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5) / 3600::double precision)::numeric(10,2) AS total_dt_s,
            ((ppf.shift_duration::double precision - (ppf.dt_0 + ppf.dt_1 + ppf.dt_2 + ppf.dt_3 + ppf.dt_4 + ppf.dt_5)) / 3600::double precision)::numeric(10,2) AS running_s,
            ((ppf.dt_0 + ppf.dt_5) / 3600::double precision)::numeric(10,2) AS dt_0,
            (ppf.dt_1 / 3600::double precision)::numeric(10,2) AS dt_1,
            (ppf.dt_2 / 3600::double precision)::numeric(10,2) AS dt_2,
            (ppf.dt_3 / 3600::double precision)::numeric(10,2) AS dt_3,
            (ppf.dt_4 / 3600::double precision)::numeric(10,2) AS dt_4,
            COALESCE(ppf.press_count, 0::double precision) AS prss_qty,
            COALESCE(ppf.net_sensor, 0::double precision) AS net_sensor,
            COALESCE(ppf.packed_qty, 0::double precision) AS packed_qty,
            shi.sequence_position AS shift_number,
            timezone('Europe/Budapest'::text, ppf.shift_start_time) AS shift_start_time,
            timezone('Europe/Budapest'::text, lower(pos.runtime_timerange_new)) AS job_sequence
           FROM press_packed_final ppf
             LEFT JOIN equipments eq ON ppf.id_equipment = eq.id_equipment AND eq.id_enterprise = 13 AND eq.tp_equipment = 3
             LEFT JOIN shifts shi ON shi.id_shift = ppf.id_shift AND shi.id_enterprise = 13
             LEFT JOIN po_sequence pos ON ppf.id_order = pos.id_order AND tstzrange(ppf.shift_start_time, ppf.shift_start_time + '12:00:00'::interval) && pos.runtime_timerange_new
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
  WHERE shift_report.day >= (timezone('Europe/Budapest'::text, now()) - '2 days'::interval);
;
-- ===VIEW=== v_13_site_wil_dt5min_piot4
CREATE VIEW public.v_13_site_wil_dt5min_piot4 AS
 WITH top_level AS (
         SELECT equipments.id_equipment,
            jsonb_array_elements(equipments.downtime_reasons) AS elem
           FROM equipments
          WHERE (equipments.id_equipment IN ( SELECT equipments_1.id_equipment
                   FROM equipments equipments_1
                  WHERE equipments_1.id_enterprise = 13 AND equipments_1.tp_equipment = 3 AND equipments_1.id_site = 37))
        ), category_level AS (
         SELECT top_level.id_equipment,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text AS description,
            (jsonb_array_elements(top_level.elem -> 'categories'::text) ->> 'code'::text)::integer AS "position"
           FROM top_level
          ORDER BY top_level.id_equipment, ((jsonb_array_elements(top_level.elem -> 'categories'::text) -> 'name'::text) ->> 'en-US'::text)
        ), downtime_codes1 AS (
         SELECT DISTINCT category_level."position",
            category_level.description,
            category_level.id_equipment
           FROM category_level
          ORDER BY category_level."position"
        ), downtime_codes AS (
         SELECT min(downtime_codes1."position") AS "position",
            downtime_codes1.description,
            downtime_codes1.id_equipment
           FROM downtime_codes1
          GROUP BY downtime_codes1.description, downtime_codes1.id_equipment
          ORDER BY (min(downtime_codes1."position")), downtime_codes1.id_equipment
        ), stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.txt_downtime_notes,
            ee.status,
            dc."position" AS downtimereason,
            ee.cd_machine,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3 AND e.id_site = 37
             LEFT JOIN downtime_codes dc ON ee.cd_category::text = dc.description AND ee.id_equipment = dc.id_equipment
          WHERE ee.status = 10 AND ee.ts_event >= (now() - '60 days'::interval) AND tstzrange(ee.ts_event, COALESCE(ee.ts_end, now())) && tstzrange(now() - '30 days'::interval, now()) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 37 AND equipments.tp_equipment = 3))
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops_final AS (
         SELECT concat(date_part('year'::text, timezone('America/New_York'::text, sb.ts_event))::text, date_part('month'::text, timezone('America/New_York'::text, sb.ts_event))::text, date_part('day'::text, timezone('America/New_York'::text, sb.ts_event))::text, 'h', date_part('hour'::text, timezone('America/New_York'::text, sb.ts_event))::text, 'm', date_part('minute'::text, timezone('America/New_York'::text, sb.ts_event))::text, sb.cd_equipment) AS index_event,
            sb.status,
            sb.cd_equipment,
            sb.ts_event,
            sb.nextts,
            sb.duration,
            sb.downtimereason,
            sb.txt_downtime_notes,
            sb.cd_machine AS nm_equipment_type
           FROM stops_neopac_ch sb
          ORDER BY sb.cd_equipment, sb.ts_event
        )
 SELECT stops_final.index_event,
    stops_final.cd_equipment,
    timezone('America/New_York'::text, stops_final.ts_event) AS ts_event,
    timezone('America/New_York'::text, stops_final.nextts) AS nextts,
    stops_final.duration,
    COALESCE(stops_final.downtimereason, 0) AS downtimereason,
    stops_final.txt_downtime_notes,
        CASE
            WHEN stops_final.nm_equipment_type::text = 'SS'::text THEN 'Sideseamer'::character varying
            WHEN stops_final.nm_equipment_type::text = 'NH'::text THEN 'Header'::character varying
            WHEN stops_final.nm_equipment_type::text = 'DM'::text THEN 'Offset'::character varying
            WHEN stops_final.nm_equipment_type::text = 'HM'::text THEN 'Capper'::character varying
            WHEN stops_final.nm_equipment_type::text = 'PM'::text THEN 'Packer'::character varying
            WHEN stops_final.nm_equipment_type::text = 'TL'::text THEN 'TL-Line'::character varying
            ELSE stops_final.nm_equipment_type
        END AS nm_equipment_type,
    13 AS id_enterprise
   FROM stops_final
  WHERE stops_final.duration > '00:05:00'::interval
  ORDER BY stops_final.cd_equipment, (timezone('America/New_York'::text, stops_final.ts_event));
;
-- ===VIEW=== v_13_site_wil_microstops_piot4
CREATE VIEW public.v_13_site_wil_microstops_piot4 AS
 WITH stops_neopac_ch AS (
         SELECT ee.ts_event,
            ee.id_equipment,
            ee.status,
            e.cd_equipment,
            COALESCE(ee.ts_end, now()) AS nextts,
            age(COALESCE(ee.ts_end, now()), ee.ts_event) AS duration
           FROM equipment_events ee
             LEFT JOIN equipments e ON ee.id_equipment = e.id_equipment AND e.id_enterprise = 13 AND e.tp_equipment = 3
          WHERE ee.ts_event >= (now() - '10 days'::interval) AND (ee.id_equipment IN ( SELECT equipments.id_equipment
                   FROM equipments
                  WHERE equipments.id_enterprise = 13 AND equipments.id_site = 37 AND equipments.tp_equipment = 3)) AND ee.status = 10
          ORDER BY e.cd_equipment, ee.ts_event
        ), stops2 AS (
         SELECT stops_neopac_ch.cd_equipment,
            date(timezone('America/New_York'::text, stops_neopac_ch.ts_event) - '06:00:00'::interval) AS dia,
                CASE
                    WHEN timezone('America/New_York'::text, stops_neopac_ch.ts_event)::time without time zone >= '05:45:00'::time without time zone AND timezone('America/New_York'::text, stops_neopac_ch.ts_event)::time without time zone <= '17:45:00'::time without time zone THEN 'T1'::text
                    ELSE 'T3'::text
                END AS turno,
            stops_neopac_ch.duration
           FROM stops_neopac_ch
          WHERE stops_neopac_ch.status = 10 AND stops_neopac_ch.duration <= '00:05:00'::interval
          ORDER BY stops_neopac_ch.cd_equipment, stops_neopac_ch.ts_event
        ), final AS (
         SELECT concat(stops2.dia, stops2.cd_equipment, stops2.turno) AS index,
            stops2.cd_equipment,
            stops2.turno,
            date_part('hour'::text, sum(stops2.duration)) * 60::double precision * 60::double precision + date_part('minutes'::text, sum(stops2.duration)) * 60::double precision + date_part('seconds'::text, sum(stops2.duration)) AS tot_duration,
            13 AS id_enterprise
           FROM stops2
          GROUP BY (concat(stops2.dia, stops2.cd_equipment, stops2.turno)), stops2.cd_equipment, stops2.dia, stops2.turno
          ORDER BY stops2.cd_equipment, stops2.dia, stops2.turno
        )
 SELECT final.index,
    final.cd_equipment,
    final.turno,
    final.tot_duration,
    final.id_enterprise
   FROM final
UNION ALL
 SELECT concat((now() - '15 days'::interval)::date, 'TL501', 'T1') AS index,
    'TL501'::character varying AS cd_equipment,
    'T1'::text AS turno,
    0 AS tot_duration,
    13 AS id_enterprise;
;

