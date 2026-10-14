-- rollback for t-drop-ca-equipment-boxes-1s — recreate silver.ca_equipment_boxes_1s exactly as it was
-- (definition, materialized_only=false, 1 s bucket, default 10-day chunks and group indexes, owner,
-- grants, comments, refresh policy 6 h / 1 min / 15 min, retention 90 d, catalog row) and restore the
-- labels_extract CTE of serving.report_shift / report_shift_pre_p3b byte-for-byte (captured from
-- staging 2026-10-14; R-lines below compare the function md5 with the captured one).
-- Not restored on purpose: the 40,109 stale 1-second invalidation ranges the old cagg had
-- accumulated (they were the cause of the 108 s refresh; the cagg held 0 rows either way).
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE MATERIALIZED VIEW IF NOT EXISTS silver.ca_equipment_boxes_1s
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
 SELECT time_bucket('00:00:01'::interval, ev.ts_value) AS ts_value,
    ((ev.analogs -> 'Label'::text) ->> 'job'::text) AS id_order,
    ev.id_equipment,
    ev.id_area,
    ev.id_site,
    ev.id_enterprise,
    sum((((ev.analogs -> 'Label'::text) ->> 'value'::text))::double precision) AS net_production,
    count((((ev.analogs -> 'Label'::text) ->> 'value'::text))::integer) AS qty
   FROM silver.equipment_values ev
  WHERE ((ev.analogs IS NOT NULL) AND (ev.analogs ? 'Label'::text))
  GROUP BY (time_bucket('00:00:01'::interval, ev.ts_value)), ((ev.analogs -> 'Label'::text) ->> 'job'::text), ev.id_equipment, ev.id_area, ev.id_site, ev.id_enterprise
WITH NO DATA;

ALTER MATERIALIZED VIEW silver.ca_equipment_boxes_1s OWNER TO postgres;
GRANT SELECT ON silver.ca_equipment_boxes_1s TO cloudbeaver_ro, readapi_ro, stream_engine;
GRANT SELECT, INSERT, UPDATE, DELETE ON silver.ca_equipment_boxes_1s TO cloudbeaver_rw;

COMMENT ON VIEW silver.ca_equipment_boxes_1s IS 'SILVER CONTINUOUS AGGREGATE (1-second bucket over silver.equipment_values). Per-second box/production count grain by PO + equipment (net_production sum and box qty), used by the box/PO counting surface.';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.ts_value IS 'Start of the 1-second time bucket (tz-aware).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_order IS 'Client-facing production order code (text; group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_equipment IS 'FK core.equipments.id_equipment (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_area IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_site IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.id_enterprise IS 'Denormalized hierarchy FK (group key).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.net_production IS 'Sum of net production in the second (count).';
COMMENT ON COLUMN silver.ca_equipment_boxes_1s.qty IS 'Count of box/production rows in the second.';

SELECT add_continuous_aggregate_policy('silver.ca_equipment_boxes_1s', start_offset => INTERVAL '6 hours',
       end_offset => INTERVAL '1 minute', schedule_interval => INTERVAL '15 minutes', if_not_exists => true);
SELECT add_retention_policy('silver.ca_equipment_boxes_1s', drop_after => INTERVAL '90 days', if_not_exists => true);
INSERT INTO ops.retention_policy (relation, kind, time_expr, keep, tier, purge_order, cold_copy, rationale)
VALUES ('silver.ca_equipment_boxes_1s', 'cagg', 'ts_value', '90 days', 'hot_raw', 100, NULL, '1 s cagg; previously unbounded.')
ON CONFLICT (relation) DO NOTHING;

-- restore the original labels_extract CTE (base64 of the exact bytes, so tabs/trailing spaces survive)
DO $mig$
DECLARE
  f    regprocedure;
  d    text;
  a    int;
  b    int;
  seg  text;
  orig constant text := convert_from(decode($b64$
KSxsYWJlbHNfZXh0cmFjdCBhcyAoLS1wZWdhIG9zIGxhYmVscywgZSBwcmVjaXNhIHNlciBoYXJkIGNvZGVkIHBvaXMgbmFvIGV4
aXN0ZSB1bWEgbG9naWMgcGFyYSBxdWFsIGVxdWlwYW1lbnRvIHRlbSBsYWJlbHMKc2VsZWN0IAoJY2EudHNfdmFsdWUgYXMgdHpf
dmFsdWUsIAoJLS1jYS5pZF9lcXVpcG1lbnQsCglsLmlkX2VxdWlwbWVudF9saW5lIGFzIGlkX2VxdWlwbWVudCwKCWNhLmlkX29y
ZGVyIGFzIGxhYmVsX0pvYiwKCWNhLm5ldF9wcm9kdWN0aW9uICBhcyBsYWJlbF9hbW91bnQKCWZyb20gY2FfZXF1aXBtZW50X2Jv
eGVzXzFzIGNhLCBsaW5oYXMgbAoJLS0gYSBqc29uIHdhcyBjcmVhdGVkIGluIHRoZSBjdXN0b20gY29sdW1uIHdpdGggYSBsb2dp
YyBmb3IgYWxsIGVxdWlwbWVudHMgdGhhdCBoYXZlIGxhYmVscyBpbiB0aGUgdGFibGUgY2FfZXF1aXBtZW50X2JveGVzXzFzCgkt
LXdoZXJlIGNhLmlkX2VxdWlwbWVudCBpbiAoMTM4LDE0NCwyMzYsMjYwLDI2NiwzMjMsMzYzLDM3NCwzODUsNDMyLDQ1OCw0ODEs
NDkyLDUwMyw1MTQsNTE4LDUyNSw1MzAsNTM1LDU0OSw1NzMsNTc4KQoJd2hlcmUgY2EuaWRfZXF1aXBtZW50IGluIChzZWxlY3Qg
aWRfZXF1aXBtZW50IGZyb20gZXF1aXBtZW50cyB3aGVyZSBpZF9lbnRlcnByaXNlID0gcF9pZF9lbnRlcnByaXNlIGFuZCBjYXN0
KGN1c3RvbTo6anNvbiM+Pid7TGFiZWwsaGFzX2xhYmVsc30nIGFzIEJPT0xFQU4pIGlzIHRydWUgYW5kIGlkX2FyZWEgPD4gYWxs
KHNlcnZpbmcucmVwb3J0X2FyZWFzX2V4Y2x1ZGVkKHBfaWRfZW50ZXJwcmlzZSkpKQoJYW5kIGNhLmlkX2VudGVycHJpc2UgPSBw
X2lkX2VudGVycHJpc2UKCWFuZCBjYS5pZF9zaXRlIGluIChzZWxlY3QgaWRfc2l0ZSBmcm9tIHNpdGVzIHdoZXJlIGlkX2VudGVy
cHJpc2UgPSBwX2lkX2VudGVycHJpc2UpCglhbmQgY2EudHNfdmFsdWUgPj0gbm93KCkgLSBpbnRlcnZhbCAnNjAgZGF5JwoJYW5k
IGNhLnRzX3ZhbHVlID49IHN0YXJ0ZGF0ZSAtIGludGVydmFsICcyMCBkYXknCglhbmQgY2EudHNfdmFsdWUgPD0gZW5kZGF0ZSAr
IGludGVydmFsICcxIGRheScKCWFuZCBjYS50c192YWx1ZSA+PSAoc2VsZWN0IG1pbihsb3dlcihydW50aW1lX3RpbWVyYW5nZSkp
IC0gaW50ZXJ2YWwgJzEyIGhvdXInIGZyb20gcHJvZF9vcmRlcnMpCglhbmQgbC5pZF9lcXVpcG1lbnQgPSBjYS5pZF9lcXVpcG1l
bnQJCg==
$b64$, 'base64'), 'UTF8');
BEGIN
  FOREACH f IN ARRAY ARRAY[to_regprocedure('serving.report_shift(integer,date,date)'),
                           to_regprocedure('serving.report_shift_pre_p3b(integer,date,date)')] LOOP
    CONTINUE WHEN f IS NULL;
    d := pg_get_functiondef(f);
    a := position('),labels_extract as (' in d);
    b := position('), negative_labels as (' in d);
    IF a = 0 OR b <= a THEN
      RAISE EXCEPTION '%: labels_extract CTE not found', f;
    END IF;
    seg := substr(d, a, b - a);
    IF seg = orig THEN
      RAISE NOTICE '%: labels_extract already original', f;
      CONTINUE;
    END IF;
    IF position('t-drop-ca-equipment-boxes-1s' in seg) = 0 THEN
      RAISE EXCEPTION '%: labels_extract is neither the stub nor the original; refusing', f;
    END IF;
    EXECUTE substr(d, 1, a - 1) || orig || substr(d, b);
    RAISE NOTICE '%: labels_extract restored', f;
  END LOOP;
END $mig$;

COMMIT;

SELECT 'R1 cagg back, real-time, 1 s: t|f|00:00:01', to_regclass('silver.ca_equipment_boxes_1s') IS NOT NULL,
       (SELECT materialized_only FROM timescaledb_information.continuous_aggregates WHERE view_schema = 'silver' AND view_name = 'ca_equipment_boxes_1s'),
       (SELECT bucket_width FROM _timescaledb_catalog.continuous_aggs_bucket_function bf JOIN _timescaledb_catalog.continuous_agg c ON c.mat_hypertable_id = bf.mat_hypertable_id
         WHERE c.user_view_schema = 'silver' AND c.user_view_name = 'ca_equipment_boxes_1s');
SELECT 'R2 refresh (6 h / 1 min / 15 min) + retention (90 d) policies: 1|1', count(*) FILTER (WHERE j.proc_name = 'policy_refresh_continuous_aggregate'
         AND j.config->>'start_offset' = '06:00:00' AND j.config->>'end_offset' = '00:01:00' AND j.schedule_interval = '15 minutes'),
       count(*) FILTER (WHERE j.proc_name = 'policy_retention' AND j.config->>'drop_after' = '90 days')
  FROM timescaledb_information.jobs j
  JOIN _timescaledb_catalog.continuous_agg c ON c.mat_hypertable_id = coalesce(j.config->>'mat_hypertable_id', j.config->>'hypertable_id')::int
 WHERE c.user_view_schema = 'silver' AND c.user_view_name = 'ca_equipment_boxes_1s';
SELECT 'R3 materialization: 10-day chunks, 6 group indexes: 864000000000|6',
       (SELECT d.interval_length FROM _timescaledb_catalog.dimension d JOIN _timescaledb_catalog.continuous_agg c ON c.mat_hypertable_id = d.hypertable_id
         WHERE c.user_view_name = 'ca_equipment_boxes_1s'),
       (SELECT count(*) FROM pg_indexes i JOIN _timescaledb_catalog.continuous_agg c ON i.tablename = '_materialized_hypertable_' || c.mat_hypertable_id
         WHERE c.user_view_name = 'ca_equipment_boxes_1s' AND i.schemaname = '_timescaledb_internal');
SELECT 'R4 report_shift md5 (staging 2026-10-14): 6a40e4ae08b8a858880326635d3362ff', md5(pg_get_functiondef('serving.report_shift(integer,date,date)'::regprocedure));
SELECT 'R5 report_shift_pre_p3b md5 (staging 2026-10-14): ed6c8b45e1f2cfc6563253784eff541a', md5(pg_get_functiondef('serving.report_shift_pre_p3b(integer,date,date)'::regprocedure));
SELECT 'R6 retention drift rows: 0', count(*) FROM ops.retention_drift;
