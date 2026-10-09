-- t-data-invariants-v4 — adds C6_shift_gross_vs_lead_silver_3d (2026-10-02)
--
-- Line-lead shifts that change off the hour took the whole boundary hour (#1545): CPACK
-- shifts averaged 10.2 pct off the lead's own silver while day totals matched, so no
-- day-grain or oracle check could see it. C6 compares every recent line-lead shift with
-- the lead's silver over the exact shift window.
-- Re-creates ops.job_data_invariants (V3 included); everything else unchanged.
-- Rollback: re-apply db/migrations/t-data-invariants-v3/01-up.sql (idempotent).
BEGIN;

CREATE OR REPLACE PROCEDURE ops.job_data_invariants(job_id int DEFAULT NULL, config jsonb DEFAULT NULL)
LANGUAGE plpgsql AS $proc$
DECLARE t timestamptz := now();
BEGIN
  SET LOCAL statement_timeout = '300s';
  -- tenants in scope: anyone with data in the last 7 days
  CREATE TEMP TABLE IF NOT EXISTS _inv_ents (id_enterprise int) ON COMMIT DROP;
  TRUNCATE _inv_ents;
  INSERT INTO _inv_ents SELECT DISTINCT id_enterprise FROM silver.equipment_values WHERE ts_value > now() - interval '7 days' AND id_enterprise IS NOT NULL;

  -- ── FRESHNESS / COMPLETENESS ─────────────────────────────────────────────
  -- C1 newest silver value per tenant (ingest stopped for a tenant)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'C1_silver_freshness_min', 'freshness', 'silver', 'critical', e.id_enterprise,
         round(extract(epoch FROM now() - max(v.ts_value)) / 60), '<= 30', now() - max(v.ts_value) <= interval '30 min', NULL
    FROM _inv_ents e JOIN silver.equipment_values v ON v.id_enterprise = e.id_enterprise AND v.ts_value > now() - interval '7 days'
   GROUP BY e.id_enterprise;
  -- C3 continuous-aggregate drift: 1h cagg vs raw silver over the last 24 complete hours (#196 frozen watermark)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'C3_cagg_vs_raw_24h', 'consistency', 'silver', 'warn', r.ent, abs(coalesce(c.s, 0) - coalesce(r.s, 0)), '<= 1',
         abs(coalesce(c.s, 0) - coalesce(r.s, 0)) <= 1, 'raw ' || round(r.s) || ' cagg ' || round(coalesce(c.s, 0))
    FROM (SELECT v.id_enterprise ent, sum(v.net_production_incr) s FROM silver.equipment_values v
           WHERE v.ts_value >= date_trunc('hour', now()) - interval '24 hours' AND v.ts_value < date_trunc('hour', now()) - interval '1 hour'
             AND v.id_enterprise IN (SELECT id_enterprise FROM _inv_ents) GROUP BY 1) r
    LEFT JOIN (SELECT e.id_enterprise ent, sum(c.net_production_incr) s FROM silver.equipment_categorical_1hour c JOIN core.equipments e USING (id_equipment)
                WHERE c.ts_value >= date_trunc('hour', now()) - interval '24 hours' AND c.ts_value < date_trunc('hour', now()) - interval '1 hour'
                  AND e.id_enterprise IN (SELECT id_enterprise FROM _inv_ents) GROUP BY 1) c USING (ent);
  -- C4 active lines missing an hourly gold row in the last 48 complete hours (provisioning)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'C4_missing_hour_rows_48h', 'completeness', 'gold', 'warn', x.ent, count(g.h) , '0', count(g.h) = 0, NULL
    FROM (SELECT e.id_enterprise ent, e.id_equipment FROM core.equipments e WHERE e.tp_equipment = 3 AND COALESCE(e.active, true) AND e.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)) x
    LEFT JOIN LATERAL (SELECT g.h FROM generate_series(date_trunc('hour', now()) - interval '48 hours', date_trunc('hour', now()) - interval '1 hour', interval '1 hour') g(h)
                        WHERE NOT EXISTS (SELECT 1 FROM gold.equipment_oee_hourly hh WHERE hh.id_equipment = x.id_equipment AND hh.ts_value = g.h)) g ON true
   GROUP BY x.ent;
  -- C5 active lines with no shift row provisioned in the next 24 h
  INSERT INTO ops.data_invariant_result
  SELECT t, 'C5_lines_without_future_shift', 'completeness', 'gold', 'warn', e.id_enterprise,
         count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM gold.equipment_oee_shift s WHERE s.id_equipment = e.id_equipment AND s.ts_value > now() AND s.ts_value < now() + interval '24 hours')),
         '0', count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM gold.equipment_oee_shift s WHERE s.id_equipment = e.id_equipment AND s.ts_value > now() AND s.ts_value < now() + interval '24 hours')) = 0, NULL
    FROM core.equipments e WHERE e.tp_equipment = 3 AND COALESCE(e.active, true) AND e.id_enterprise IN (SELECT id_enterprise FROM _inv_ents) GROUP BY 6;
  -- L1 PLC link: link-monitored endpoints with no report for 10 min (box / reader / agent dead)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'L1_link_endpoints_silent_10min', 'freshness', 'source', 'critical', m.id_enterprise,
         count(*) FILTER (WHERE m.last < now() - interval '10 minutes'), '0',
         count(*) FILTER (WHERE m.last < now() - interval '10 minutes') = 0,
         string_agg(m.endpoint, ',') FILTER (WHERE m.last < now() - interval '10 minutes')
    FROM (SELECT id_enterprise, endpoint, max(ts_minute) last FROM silver.plc_link_minutes WHERE ts_minute > now() - interval '7 days' GROUP BY 1, 2) m GROUP BY m.id_enterprise;
  -- L2 PLC link: endpoints whose PLC could not be read for the whole last hour (info: a known dead PLC shows here)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'L2_link_endpoints_unreachable_1h', 'completeness', 'source', 'info', m.id_enterprise,
         count(*) FILTER (WHERE m.ok = 0), '0', count(*) FILTER (WHERE m.ok = 0) = 0, string_agg(m.endpoint, ',') FILTER (WHERE m.ok = 0)
    FROM (SELECT id_enterprise, endpoint, sum(ok_ticks) ok FROM silver.plc_link_minutes WHERE ts_minute > now() - interval '1 hour' GROUP BY 1, 2) m GROUP BY m.id_enterprise;

  -- ── ORCHESTRATION ────────────────────────────────────────────────────────
  -- O1 compute liveness per grain (minutes since the newest computed_at)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'O1_' || g.name || '_last_compute_min', 'orchestration', 'gold', 'critical', NULL,
         round(extract(epoch FROM now() - g.last) / 60), '<= ' || g.lim, now() - g.last <= (g.lim || ' minutes')::interval, NULL
    FROM (SELECT 'hour' name, (SELECT max(computed_at) FROM gold.equipment_oee_hourly WHERE computed_at > now() - interval '2 days') last, 15 lim
          UNION ALL SELECT 'shift', (SELECT max(computed_at) FROM gold.equipment_oee_shift WHERE computed_at > now() - interval '2 days'), 15
          UNION ALL SELECT 'day', (SELECT max(computed_at) FROM gold.equipment_oee_daily WHERE computed_at > now() - interval '2 days'), 60
          UNION ALL SELECT 'po', (SELECT max(last_update) FROM gold.production_orders_runtime WHERE last_update > now() - interval '2 days'), 30) g;
  -- O2 oldest in-window flags (a queue that is not draining) — shift rollup stall 2026-10-01
  INSERT INTO ops.data_invariant_result
  SELECT t, 'O2_hour_oldest_flag_h', 'orchestration', 'gold', 'warn', NULL, coalesce(round(extract(epoch FROM now() - min(ts_value)) / 3600), 0), '<= 12',
         coalesce(min(ts_value) >= now() - interval '12 hours', true), NULL
    FROM gold.equipment_oee_hourly WHERE recalc_needed AND ts_value < now() - interval '65 minutes' AND ts_value >= now() - interval '10 days';
  INSERT INTO ops.data_invariant_result
  SELECT t, 'O2_shift_flags_not_computed_6h', 'orchestration', 'gold', 'warn', NULL,
         count(*) FILTER (WHERE coalesce(computed_at, '-infinity') < now() - interval '6 hours'), '0',
         count(*) FILTER (WHERE coalesce(computed_at, '-infinity') < now() - interval '6 hours') = 0, NULL
    FROM gold.equipment_oee_shift WHERE recalc_needed AND ts_value <= now() - interval '1 day' AND ts_value >= now() - interval '30 days';
  -- O3 stranded flags (must be 0 after the hourly sweep, #1541)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'O3_stranded_flags', 'orchestration', 'gold', 'warn', NULL, x.n, '0', x.n = 0, NULL
    FROM (SELECT (SELECT count(*) FROM gold.production_orders_runtime WHERE recalc_needed AND upper(runtime_timerange) < now() - interval '1 month' - interval '2 hours')
               + (SELECT count(*) FROM core.production_orders WHERE recalc_needed AND status IN (3, 4) AND COALESCE(ts_end, ts_start) < now() - interval '1 month' - interval '2 hours')
               + (SELECT count(*) FROM gold.equipment_oee_shift WHERE recalc_needed AND ts_value < now() - interval '30 days' - interval '2 hours')
               + (SELECT count(*) FROM gold.equipment_oee_hourly WHERE recalc_needed AND ts_value < now() - interval '10 days' - interval '2 hours') AS n) x;
  -- O4 PO state: finished PO with an open run (re-flag ping-pong, PO 25126)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'O4_finished_po_open_run', 'consistency', 'gold', 'warn', NULL, count(*), '0', count(*) = 0, string_agg(DISTINCT r.id_production_order::text, ',')
    FROM gold.production_orders_runtime r JOIN core.production_orders p USING (id_production_order) WHERE upper(r.runtime_timerange) IS NULL AND p.status IN (3, 4);
  -- O5 POs "running" for more than 30 days (abandoned / never stopped)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'O5_running_po_gt30d', 'consistency', 'gold', 'info', p.id_enterprise, count(*), '0', count(*) = 0, string_agg(p.id_production_order::text, ',')
    FROM core.production_orders p WHERE p.status = 2 AND p.ts_start < now() - interval '30 days' AND p.id_enterprise IN (SELECT id_enterprise FROM _inv_ents) GROUP BY p.id_enterprise;

  -- ── CONSISTENCY ACROSS GRAINS ────────────────────────────────────────────
  -- K1 day = Σ hour (lines, yesterday's production day: net, available, out-of-service)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'K1_day_eq_sum_hours', 'consistency', 'gold', 'warn', e.id_enterprise,
         count(*) FILTER (WHERE abs(coalesce(d.net, 0) - coalesce(h.net, 0)) > 1 OR coalesce(d.out_of_service_time, 0) <> coalesce(h.oos, 0)), '0',
         count(*) FILTER (WHERE abs(coalesce(d.net, 0) - coalesce(h.net, 0)) > 1 OR coalesce(d.out_of_service_time, 0) <> coalesce(h.oos, 0)) = 0,
         string_agg(e.nm_equipment, ',') FILTER (WHERE abs(coalesce(d.net, 0) - coalesce(h.net, 0)) > 1)
    FROM gold.equipment_oee_daily d JOIN core.equipments e USING (id_equipment)
    JOIN (SELECT id_equipment, ts_value_production AS pday, sum(net) net, sum(out_of_service_time) oos FROM gold.equipment_oee_hourly
           WHERE ts_value_production = current_date - 1 GROUP BY 1, 2) h ON h.id_equipment = d.id_equipment AND h.pday = d.ts_value
   WHERE e.tp_equipment = 3 AND d.ts_value = current_date - 1 AND NOT d.recalc_needed AND e.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)
   GROUP BY e.id_enterprise;
  -- K2 week = Σ day (last complete week)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'K2_week_eq_sum_days', 'consistency', 'gold', 'warn', e.id_enterprise, count(*) FILTER (WHERE abs(coalesce(w.net, 0) - coalesce(s.net, 0)) > 1), '0',
         count(*) FILTER (WHERE abs(coalesce(w.net, 0) - coalesce(s.net, 0)) > 1) = 0, NULL
    FROM gold.equipment_oee_weekly w JOIN core.equipments e USING (id_equipment)
    JOIN (SELECT id_equipment, date_trunc('week', ts_value)::date wk, sum(net) net FROM gold.equipment_oee_daily
           WHERE ts_value >= (date_trunc('week', now()) - interval '7 days')::date AND ts_value < date_trunc('week', now())::date GROUP BY 1, 2) s
      ON s.id_equipment = w.id_equipment AND s.wk = w.ts_value
   WHERE e.tp_equipment = 3 AND w.ts_value = (date_trunc('week', now()) - interval '7 days')::date AND NOT w.recalc_needed AND e.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)
   GROUP BY e.id_enterprise;
  -- K3 area day = Σ its lines (yesterday)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'K3_area_eq_sum_lines', 'consistency', 'gold', 'warn', a.id_enterprise,
         count(*) FILTER (WHERE abs(coalesce(ad.net, 0) - coalesce(s.net, 0)) > 1 OR abs(coalesce(ad.available_time, 0) - coalesce(s.av, 0)) > 1), '0',
         count(*) FILTER (WHERE abs(coalesce(ad.net, 0) - coalesce(s.net, 0)) > 1 OR abs(coalesce(ad.available_time, 0) - coalesce(s.av, 0)) > 1) = 0, NULL
    FROM gold.area_oee_daily ad JOIN core.areas a USING (id_area)
    JOIN (SELECT e.id_area, sum(d.net) net, sum(d.available_time) av FROM gold.equipment_oee_daily d JOIN core.equipments e USING (id_equipment)
           WHERE e.tp_equipment = 3 AND d.ts_value = current_date - 1 GROUP BY 1) s ON s.id_area = ad.id_area
   WHERE ad.ts_value = current_date - 1 AND NOT ad.recalc_needed AND a.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)
   GROUP BY a.id_enterprise;
  -- K4 OEE identity + physical time bounds on hourly gold (48 h)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'K4_hourly_identity_and_bounds', 'validity', 'gold', 'warn', e.id_enterprise,
         count(*) FILTER (WHERE abs(coalesce(h.oee, 0) - coalesce(h.oee_a, 0) * coalesce(h.oee_p, 0) * coalesce(h.oee_q, 0)) > 1e-6
                             OR h.running_time > h.available_time + 1 OR h.available_time > 3600
                             OR least(h.running_time, h.available_time, h.stopped_time, h.downtime, h.no_data_time, h.out_of_service_time) < 0), '0',
         count(*) FILTER (WHERE abs(coalesce(h.oee, 0) - coalesce(h.oee_a, 0) * coalesce(h.oee_p, 0) * coalesce(h.oee_q, 0)) > 1e-6
                             OR h.running_time > h.available_time + 1 OR h.available_time > 3600
                             OR least(h.running_time, h.available_time, h.stopped_time, h.downtime, h.no_data_time, h.out_of_service_time) < 0) = 0, NULL
    FROM gold.equipment_oee_hourly h JOIN core.equipments e USING (id_equipment)
   WHERE h.ts_value > now() - interval '48 hours' AND h.ts_value < now() - interval '2 hours' AND NOT h.recalc_needed AND e.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)
   GROUP BY e.id_enterprise;
  -- K5 serving downtime copy = silver stops (7 d) — serving duplicates/holes (#1529)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'K5_serving_downtime_vs_silver_7d', 'consistency', 'serving', 'warn', ev.id_enterprise, abs(ev.n - coalesce(s.n, 0)), '0',
         ev.n = coalesce(s.n, 0), 'silver ' || ev.n || ' serving ' || coalesce(s.n, 0)
    FROM (SELECT ee.id_enterprise, count(*) n FROM silver.equipment_events ee JOIN core.equipments eq USING (id_equipment)
           WHERE ee.ts_event > now() - interval '7 days' AND ee.ts_event < now() - interval '15 minutes' AND ee.status NOT IN (6, 20) AND eq.event_should_be_displayed
             AND ee.id_enterprise IN (SELECT id_enterprise FROM _inv_ents) GROUP BY 1) ev
    LEFT JOIN (SELECT id_enterprise, count(*) n FROM serving.downtime_events_resolved WHERE NOT manual_event AND ts_event > now() - interval '7 days' AND ts_event < now() - interval '15 minutes' GROUP BY 1) s USING (id_enterprise);
  -- K6 sandbox twin parity: yesterday's line net CPACK (3) = twin (2000003)
  IF EXISTS (SELECT 1 FROM core.equipments WHERE id_enterprise = 2000003) THEN
    INSERT INTO ops.data_invariant_result
    SELECT t, 'K6_twin_daily_net_parity', 'consistency', 'gold', 'info', 2000003, abs(coalesce(a, 0) - coalesce(b, 0)), '<= 1', abs(coalesce(a, 0) - coalesce(b, 0)) <= 1,
           'cpack ' || round(a) || ' twin ' || round(b)
      FROM (SELECT sum(d.net) FILTER (WHERE e.id_enterprise = 3) a, sum(d.net) FILTER (WHERE e.id_enterprise = 2000003) b
              FROM gold.equipment_oee_daily d JOIN core.equipments e USING (id_equipment) WHERE e.tp_equipment = 3 AND d.ts_value = current_date - 1 AND e.id_enterprise IN (3, 2000003)) x;
  END IF;

  -- ── VALIDITY ──────────────────────────────────────────────────────────────
  -- V1 counters frozen at an integer ceiling (factory tee saturation, PTH 32767)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'V1_saturated_counters', 'validity', 'source', 'warn', x.id_enterprise, count(*), '0', count(*) = 0, string_agg(x.id_equipment::text, ',')
    FROM (SELECT DISTINCT ON (id_equipment) id_equipment, id_enterprise, gross_production_val g, net_production_val n FROM silver.equipment_values
           WHERE ts_value > now() - interval '1 day' AND (gross_production_val IS NOT NULL OR net_production_val IS NOT NULL) ORDER BY id_equipment, ts_value DESC) x
   WHERE x.g IN (32767, 65535, 2147483647) OR x.n IN (32767, 65535, 2147483647) GROUP BY x.id_enterprise;
  -- V2 ingest increments rejected as impossible in the last hour (spike / reset storm)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'V2_ingest_rejects_1h', 'validity', 'silver', 'warn', q.id_enterprise, count(*), '<= 30', count(*) <= 30, NULL
    FROM silver.data_quality_event q WHERE q.rule = 'INVARIANT_CLAMPED_INCREMENT' AND q.detected_at > now() - interval '1 hour' GROUP BY q.id_enterprise;

  -- V3 increments NOT backed by their own totalizer (2 h) — a stale upstream baseline after a gap or
  -- restart: Bispharma M673 09-25 wrote 263,098 while its counter moved 4; 13 machines on 09-18; CPACK
  -- restart bursts (+125 vs counter +25). Same rule as the stream-engine ingest guard (unbacked >= 100
  -- and more than half the increment), so a hit means the guard is off or bypassed.
  INSERT INTO ops.data_invariant_result
  SELECT t, 'V3_unbacked_increments_2h', 'validity', 'silver', 'warn', e.id_enterprise, count(x.id_equipment), '0', count(x.id_equipment) = 0,
         string_agg(DISTINCT x.id_equipment::text, ',')
    FROM _inv_ents e LEFT JOIN LATERAL (
    SELECT v.id_equipment FROM silver.equipment_values v
     CROSS JOIN LATERAL (SELECT p.net_production_val pv FROM silver.equipment_values p WHERE p.id_equipment = v.id_equipment AND p.ts_value < v.ts_value
                           AND p.ts_value > v.ts_value - interval '30 days' AND p.net_production_val IS NOT NULL ORDER BY p.ts_value DESC LIMIT 1) p
     WHERE v.id_enterprise = e.id_enterprise AND v.ts_value > now() - interval '2 hours' AND v.net_production_incr >= 100 AND v.net_production_val >= p.pv
       AND v.net_production_incr - (v.net_production_val - p.pv) >= 100 AND 2 * (v.net_production_incr - (v.net_production_val - p.pv)) > v.net_production_incr
    UNION ALL
    SELECT v.id_equipment FROM silver.equipment_values v
     CROSS JOIN LATERAL (SELECT p.gross_production_val pv FROM silver.equipment_values p WHERE p.id_equipment = v.id_equipment AND p.ts_value < v.ts_value
                           AND p.ts_value > v.ts_value - interval '30 days' AND p.gross_production_val IS NOT NULL ORDER BY p.ts_value DESC LIMIT 1) p
     WHERE v.id_enterprise = e.id_enterprise AND v.ts_value > now() - interval '2 hours' AND v.gross_production_incr >= 100 AND v.gross_production_val >= p.pv
       AND v.gross_production_incr - (v.gross_production_val - p.pv) >= 100 AND 2 * (v.gross_production_incr - (v.gross_production_val - p.pv)) > v.gross_production_incr
    ) x ON true GROUP BY e.id_enterprise;

  -- C6 line-lead SHIFT gross = the lead's own silver over the exact shift window (3 d, shifts ended > 2 h
  -- ago, leads that report gross with the default counter role). #1545: shifts changing off the hour
  -- took the whole boundary hour (CPACK avg 10.2 pct per shift, day totals fine). Warn when > 2 pct off.
  INSERT INTO ops.data_invariant_result
  SELECT t, 'C6_shift_gross_vs_lead_silver_3d', 'consistency', 'gold', 'warn', e.id_enterprise,
         count(x.id_equipment), '0', count(x.id_equipment) = 0, string_agg(DISTINCT x.nm, ',')
    FROM _inv_ents e LEFT JOIN LATERAL (
      SELECT s.id_equipment, q.nm_equipment nm
        FROM gold.equipment_oee_shift s JOIN core.equipments q USING (id_equipment)
       CROSS JOIN LATERAL (SELECT sum(v.gross_production_incr) g FROM silver.equipment_values v
                            WHERE v.id_equipment = q.lead_machine AND v.ts_value >= s.ts_value AND v.ts_value < s.ts_end
                              AND v.ts_value > now() - interval '4 days') sv
       WHERE q.id_enterprise = e.id_enterprise AND q.tp_equipment = 3 AND COALESCE(q.lead_machine, 0) > 0
         AND q.gross_machine IS NULL AND q.gross_counter IS NULL
         AND s.ts_value > now() - interval '3 days' AND s.ts_end < now() - interval '2 hours'
         AND sv.g > 100 AND abs(s.gross - sv.g) > 0.02 * sv.g
    ) x ON true GROUP BY e.id_enterprise;

  -- ── REFERENTIAL / ISOLATION ──────────────────────────────────────────────
  -- R1 silver rows for equipment that no longer exists (7 d) — Bispharma 2000109 orphans
  INSERT INTO ops.data_invariant_result
  SELECT t, 'R1_orphan_silver_7d', 'referential', 'silver', 'warn', NULL,
         (SELECT count(DISTINCT v.id_equipment) FROM silver.equipment_values v WHERE v.ts_value > now() - interval '7 days' AND NOT EXISTS (SELECT 1 FROM core.equipments e WHERE e.id_equipment = v.id_equipment))
       + (SELECT count(*) FROM silver.equipment_events v WHERE v.ts_event > now() - interval '7 days' AND NOT EXISTS (SELECT 1 FROM core.equipments e WHERE e.id_equipment = v.id_equipment)),
         '0', true, NULL;
  UPDATE ops.data_invariant_result SET ok = (observed = 0) WHERE run_at = t AND check_id = 'R1_orphan_silver_7d';
  -- R2 active routing to missing equipment / to another tenant's equipment
  INSERT INTO ops.data_invariant_result
  SELECT t, 'R2_routing_bad', 'referential', 'config', 'warn', NULL, count(*) FILTER (WHERE e.id_equipment IS NULL OR e.id_enterprise <> tr.id_enterprise), '0',
         count(*) FILTER (WHERE e.id_equipment IS NULL OR e.id_enterprise <> tr.id_enterprise) = 0, NULL
    FROM core.topic_routing tr LEFT JOIN core.equipments e ON e.id_equipment = tr.id_equipment WHERE tr.active;
  -- R3 line role machines (lead/gross/net/scrap): missing, another tenant (twin cross-tenant read, #1528) or not on the line
  INSERT INTO ops.data_invariant_result
  SELECT t, 'R3_line_roles_bad', 'isolation', 'config', 'warn', l.id_enterprise, count(*), '0', count(*) = 0, string_agg(l.nm_equipment || '.' || r.role, ',')
    FROM core.equipments l
    CROSS JOIN LATERAL (VALUES ('lead', l.lead_machine), ('gross', l.gross_machine), ('net', l.net_machine), ('scrap', l.scrap_machine)) r(role, id)
    LEFT JOIN core.equipments m ON m.id_equipment = r.id
   WHERE l.tp_equipment = 3 AND COALESCE(r.id, 0) > 0 AND l.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)
     AND (m.id_equipment IS NULL OR m.id_enterprise <> l.id_enterprise
          OR (m.id_parentequipment IS DISTINCT FROM l.id_equipment
              AND NOT EXISTS (SELECT 1 FROM core.equipments s WHERE s.id_equipment = m.id_parentequipment AND s.id_parentequipment = l.id_equipment)))
   GROUP BY l.id_enterprise;
  -- R4 PO runs on missing equipment / another tenant than the header (60 d)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'R4_po_runtime_bad', 'referential', 'gold', 'warn', NULL, count(*) FILTER (WHERE e.id_equipment IS NULL OR e.id_enterprise <> p.id_enterprise), '0',
         count(*) FILTER (WHERE e.id_equipment IS NULL OR e.id_enterprise <> p.id_enterprise) = 0, NULL
    FROM gold.production_orders_runtime r JOIN core.production_orders p USING (id_production_order) LEFT JOIN core.equipments e ON e.id_equipment = r.id_equipment
   WHERE lower(r.runtime_timerange) > now() - interval '60 days';

  -- ── PROVENANCE / SEMANTICS ───────────────────────────────────────────────
  -- P1 counts in a minute whose PLC link reported ONLY failures (data not from that PLC: simulator, replay of the wrong source)
  WITH bad AS MATERIALIZED (
      SELECT pe.id_equipment::int AS id_equipment, pl.ts_minute
        FROM silver.plc_link_minutes pl
        JOIN (SELECT DISTINCT id_enterprise, endpoint, id_equipment FROM silver.plc_endpoint_equipment) pe
          ON pe.id_enterprise = pl.id_enterprise AND pe.endpoint = pl.endpoint
       WHERE pl.ts_minute > now() - interval '24 hours' AND pl.ok_ticks = 0 AND pl.fail_ticks > 0)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'P1_counts_while_plc_unreadable_24h', 'provenance', 'silver', 'warn', NULL, count(*), '0', count(*) = 0, NULL
    FROM bad b
   WHERE EXISTS (SELECT 1 FROM silver.equipment_values v
                  WHERE v.id_equipment = b.id_equipment
                    AND v.ts_value > now() - interval '25 hours'          -- constant bound: chunk exclusion
                    AND v.ts_value >= b.ts_minute AND v.ts_value < b.ts_minute + interval '1 minute'
                    AND (coalesce(v.net_production_incr, 0) > 0 OR coalesce(v.gross_production_incr, 0) > 0));
  -- P2 production inside an out-of-service window (window wrong, or data not real)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'P2_production_in_out_of_service', 'provenance', 'gold', 'warn', o.id_enterprise, count(*), '0', count(*) = 0, NULL
    FROM gold.equipment_oee_hourly h JOIN config.equipment_out_of_service o ON o.id_equipment = h.id_equipment AND o.period @> h.ts_value
   WHERE (h.gross > 0 OR h.net > 0) AND h.ts_value > now() - interval '7 days' GROUP BY o.id_enterprise;
  -- S1 no-fill lines: gold gross must equal the raw gross meter (7 d) — L90 identity-fill double count
  INSERT INTO ops.data_invariant_result
  SELECT t, 'S1_nofill_line_gold_vs_raw_7d', 'accuracy', 'gold', 'warn', x.ent, max(abs(x.gold - x.raw) / nullif(x.raw, 0)), '<= 0.005',
         coalesce(max(abs(x.gold - x.raw) / nullif(x.raw, 0)) <= 0.005, true), string_agg(x.nm, ',') FILTER (WHERE abs(x.gold - x.raw) > 0.005 * x.raw)
    FROM (SELECT l.id_enterprise ent, l.nm_equipment nm,
                 (SELECT sum(h.gross) FROM gold.equipment_oee_hourly h WHERE h.id_equipment = l.id_equipment AND h.ts_value >= date_trunc('hour', now()) - interval '7 days' AND h.ts_value < date_trunc('hour', now()) - interval '2 hours') gold,
                 (SELECT sum(CASE WHEN l.gross_counter = 'processed' THEN c.net_production_incr ELSE c.gross_production_incr END) FROM silver.equipment_categorical_1hour c
                   WHERE c.id_equipment = COALESCE(l.gross_machine, l.lead_machine) AND c.ts_value >= date_trunc('hour', now()) - interval '7 days' AND c.ts_value < date_trunc('hour', now()) - interval '2 hours') raw
            FROM core.equipments l WHERE l.tp_equipment = 3 AND l.fill_missing_meter IS FALSE) x
   GROUP BY x.ent;
  -- S2 STALE open stop: open > 1 day although the machine produced at least ONE HOUR of ideal
  -- output after it started — the stop should have closed (L58 15-day phantom). A dormant
  -- machine's open stop is correct (no production since); a few hundred units counted during a
  -- labelled stop is a source fact the oracle shares (CPACK POLYTYPE1 PRG-12, 2026-09-30), not stale.
  INSERT INTO ops.data_invariant_result
  SELECT t, 'S2_stale_open_stops', 'semantics', 'silver', 'warn', ev.id_enterprise, count(*), '0', count(*) = 0, string_agg(ev.id_equipment::text, ',')
    FROM silver.equipment_events ev
    JOIN core.equipments e ON e.id_equipment = ev.id_equipment
    CROSS JOIN LATERAL (SELECT sum(coalesce(c.net_production_incr, 0) + coalesce(c.gross_production_incr, 0)) AS prod
                          FROM silver.equipment_categorical_1hour c
                         WHERE c.id_equipment = ev.id_equipment AND c.ts_value > ev.ts_event + interval '1 hour'
                           AND c.ts_value > now() - interval '90 days') p
   WHERE ev.ts_end IS NULL AND ev.status IN (5, 10, 11) AND ev.ts_event < now() - interval '1 day' AND ev.ts_event > now() - interval '90 days'
     AND ev.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)
     AND coalesce(p.prod, 0) > 60 * coalesce(nullif(e.production_speed, 0),
                                             (SELECT nullif(m.production_speed, 0) FROM core.equipments m WHERE m.id_equipment = e.lead_machine), 1000.0 / 60)
   GROUP BY ev.id_enterprise;
  -- S3 an open NO DATA (status 20) on a PLC whose link is healthy now (deriver ↔ link disagreement)
  INSERT INTO ops.data_invariant_result
  SELECT t, 'S3_nodata_open_but_link_ok', 'semantics', 'silver', 'warn', NULL, count(*), '0', count(*) = 0, NULL
    FROM silver.equipment_events ev JOIN silver.plc_endpoint_equipment pe ON pe.id_equipment = ev.id_equipment
   WHERE ev.status = 20 AND ev.ts_end IS NULL AND ev.ts_event < now() - interval '30 minutes'
     AND EXISTS (SELECT 1 FROM silver.plc_link_minutes pl WHERE pl.id_enterprise = pe.id_enterprise AND pl.endpoint = pe.endpoint AND pl.ts_minute > now() - interval '15 minutes' AND pl.ok_ticks > 0);

  -- ── CONFIG (info: needs a human decision, shown not paged) ───────────────
  INSERT INTO ops.data_invariant_result
  SELECT t, 'F1_lines_without_daily_target', 'config', 'config', 'info', l.id_enterprise,
         count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM config.production_targets pt WHERE pt.id_equipment = l.id_equipment AND coalesce(pt.vl_day, 0) > 0)), '0',
         count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM config.production_targets pt WHERE pt.id_equipment = l.id_equipment AND coalesce(pt.vl_day, 0) > 0)) = 0, NULL
    FROM core.equipments l WHERE l.tp_equipment = 3 AND COALESCE(l.active, true) AND l.id_enterprise IN (SELECT id_enterprise FROM _inv_ents) GROUP BY l.id_enterprise;
  INSERT INTO ops.data_invariant_result
  SELECT t, 'F2_lead_stops_hidden', 'config', 'config', 'warn', l.id_enterprise, count(*), '0', count(*) = 0, string_agg(l.nm_equipment, ',')
    FROM core.equipments l JOIN core.equipments m ON m.id_equipment = l.lead_machine
   WHERE l.tp_equipment = 3 AND l.downtime_from_lead_machine AND m.event_should_be_displayed IS NOT TRUE AND l.id_enterprise IN (SELECT id_enterprise FROM _inv_ents)
   GROUP BY l.id_enterprise;

  -- the checker's own heartbeat (DataInvariantsStale alerts when this is old)
  INSERT INTO ops.data_invariant_result VALUES (t, 'Z_invariants_run', 'orchestration', 'ops', 'info', NULL, extract(epoch FROM clock_timestamp() - t), NULL, true, 'seconds to run', 'db');
  DELETE FROM ops.data_invariant_result WHERE run_at < now() - interval '14 days';
END
$proc$;

COMMIT;
