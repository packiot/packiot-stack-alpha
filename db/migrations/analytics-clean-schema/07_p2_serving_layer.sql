\pset pager off
\set ON_ERROR_STOP off
CREATE SCHEMA IF NOT EXISTS serving;
COMMENT ON SCHEMA serving IS 'Clean serving surface (intent-named). Replaces Hasura-era h_piot_* SETOF functions + their 0-row return-type tables with security_invoker views + real composite types. Analytics clean-schema P2, 2026-09-08.';

-- serving.machine_speed — silver-backed per-minute speed (the clean replacement for
-- h_piot_machine_speed / bi.equipment_speed's inferred-speed path). Speed is the exact
-- decomposable weighted mean sum_speed/cnt_speed. security_invoker => RLS binds to caller.
CREATE OR REPLACE VIEW serving.machine_speed WITH (security_invoker=true) AS
SELECT eq.id_enterprise, m.id_equipment, eq.nm_equipment, m.bucket AS ts_value,
  (m.sum_speed / NULLIF(m.cnt_speed,0)) AS speed, m.max_speed AS plc_speed_max,
  eq.production_speed AS ideal_production_speed,
  m.sum_gross, m.sum_net, m.sum_scrap, m.cnt_rows, m.tp_equipment,
  eq.nm_equipment::text || CASE eq.tp_equipment WHEN 3 THEN ' (line)'::text WHEN 1 THEN ' (machine)'::text WHEN 2 THEN ' (sector)'::text ELSE ''::text END AS equipment_label
FROM silver.equipment_metrics_1min m JOIN public.equipments eq ON eq.id_equipment = m.id_equipment;

-- §4 pattern: real composite TYPE replacing the 0-row SETOF return-type "tables".
DROP TYPE IF EXISTS serving.oee_score_row CASCADE;
CREATE TYPE serving.oee_score_row AS (
  id_enterprise int, id_equipment int, ts_value timestamptz, ts_end timestamptz,
  oee double precision, oee_a double precision, oee_p double precision, oee_q double precision,
  gross double precision, net double precision, running_time double precision
);

-- serving.oee_score — canonical A·P·Q. Serving SUMs the STORED Gold factors and
-- re-derives OEE from the summed components; it NEVER recomputes the headline top-down
-- (kills the two-definition bug, PoC §5.3). Reads GOLD equipment_oee_shift.
CREATE OR REPLACE FUNCTION serving.oee_score(
  in_id_enterprise int, _tsstart timestamptz, _tsend timestamptz)
RETURNS SETOF serving.oee_score_row
LANGUAGE sql STABLE AS $$
  SELECT eq.id_enterprise, rs.id_equipment, min(rs.ts_value), max(rs.ts_end),
    -- canonical: OEE re-derived from summed factors weighted by running_time
    CASE WHEN sum(rs.running_time)>0
      THEN (sum(rs.oee_a*rs.running_time)/sum(rs.running_time))
         * (sum(rs.oee_p*rs.running_time)/sum(rs.running_time))
         * (sum(rs.oee_q*rs.running_time)/sum(rs.running_time)) ELSE 0 END AS oee,
    CASE WHEN sum(rs.running_time)>0 THEN sum(rs.oee_a*rs.running_time)/sum(rs.running_time) ELSE 0 END AS oee_a,
    CASE WHEN sum(rs.running_time)>0 THEN sum(rs.oee_p*rs.running_time)/sum(rs.running_time) ELSE 0 END AS oee_p,
    CASE WHEN sum(rs.running_time)>0 THEN sum(rs.oee_q*rs.running_time)/sum(rs.running_time) ELSE 0 END AS oee_q,
    sum(rs.gross), sum(rs.net), sum(rs.running_time)
  FROM public.equipment_oee_shift rs JOIN public.equipments eq ON eq.id_equipment=rs.id_equipment
  WHERE eq.id_enterprise = in_id_enterprise AND rs.ts_value >= _tsstart AND rs.ts_value < _tsend AND rs.running_time > 0
  GROUP BY eq.id_enterprise, rs.id_equipment;
$$;

GRANT USAGE ON SCHEMA serving TO superset_ro, bi_owner;
GRANT SELECT ON ALL TABLES IN SCHEMA serving TO superset_ro, bi_owner;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA serving TO superset_ro, bi_owner;
\echo === serving objects ===
SELECT 'view '||relname FROM pg_class WHERE relnamespace='serving'::regnamespace AND relkind='v'
UNION ALL SELECT 'type '||typname FROM pg_type WHERE typnamespace='serving'::regnamespace AND typtype='c' AND typname='oee_score_row'
UNION ALL SELECT 'func '||proname FROM pg_proc WHERE pronamespace='serving'::regnamespace;
