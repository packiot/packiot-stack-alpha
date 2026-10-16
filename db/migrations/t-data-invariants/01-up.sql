-- t-data-invariants — standing data-architecture invariants (2026-10-01)
--
-- The 2026-09/10 audits found failures that no alert could see: a dead PLC read as
-- "stopped", a simulator feeding a real tenant, a split meter double-counted,
-- serving duplicates, recompute flags that could never drain, data holes vs the
-- legacy oracle, a stalled shift rollup, a factory feed gone silent. Each was found
-- by hand. This migration turns that battery into a standing guard:
--   ops.job_data_invariants (Timescale job, every 30 min) runs every in-DB check
--   below into ops.data_invariant_result; ops.data_invariant_latest is the latest
--   result per check × tenant; postgres-exporter exposes it and Prometheus alerts
--   (DataInvariantFailing / DataInvariantsStale) page Slack via Alertmanager.
-- Checks against the legacy oracle (another DB) are written into the same table by
-- scripts/ops/data-oracle-check.sh (systemd timer), so they alert the same way.
--
-- Dimensions: completeness · freshness · consistency · accuracy · validity ·
-- uniqueness · referential · provenance · semantics · orchestration · config ·
-- isolation. severity: critical (data stops) · warn (data wrong) · info (shown, not paged).
-- Each check = one hardproofed audit query; comments name the incident it encodes.
BEGIN;

CREATE TABLE IF NOT EXISTS ops.data_invariant_result (
    run_at        timestamptz NOT NULL,
    check_id      text        NOT NULL,
    dimension     text        NOT NULL,
    layer         text        NOT NULL,
    severity      text        NOT NULL CHECK (severity IN ('critical', 'warn', 'info')),
    id_enterprise integer,
    observed      numeric,
    expected      text,
    ok            boolean     NOT NULL,
    detail        text,
    source        text        NOT NULL DEFAULT 'db'
);
CREATE INDEX IF NOT EXISTS data_invariant_result_run_idx ON ops.data_invariant_result (check_id, id_enterprise, run_at DESC);
COMMENT ON TABLE ops.data_invariant_result IS
  'Standing data invariants (t-data-invariants): one row per check × tenant per run. Written by ops.job_data_invariants (in-DB, every 30 min) and scripts/ops/data-oracle-check.sh (legacy oracle). Kept 14 days.';

CREATE OR REPLACE VIEW ops.data_invariant_latest AS
SELECT DISTINCT ON (check_id, coalesce(id_enterprise, -1)) *
  FROM ops.data_invariant_result
 WHERE run_at > now() - interval '1 day'
 ORDER BY check_id, coalesce(id_enterprise, -1), run_at DESC;

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
COMMENT ON PROCEDURE ops.job_data_invariants(int, jsonb) IS 'Runs the in-DB data invariants into ops.data_invariant_result (t-data-invariants). Timescale job, every 30 min.';

GRANT SELECT ON ops.data_invariant_result, ops.data_invariant_latest TO PUBLIC;

-- schedule (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM timescaledb_information.jobs WHERE proc_schema = 'ops' AND proc_name = 'job_data_invariants') THEN
    PERFORM add_job('ops.job_data_invariants', '30 minutes', initial_start => now() + interval '1 minute');
  END IF;
END $$;

COMMIT;
