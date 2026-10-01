-- Expect: endpoints mapped per tenant; after the reader rollout, recent minutes per endpoint.
SELECT id_enterprise, count(DISTINCT endpoint) AS endpoints, count(*) AS equipment FROM silver.plc_endpoint_equipment GROUP BY 1 ORDER BY 1;
SELECT id_enterprise, endpoint, max(ts_minute) AS last_minute,
       sum(ok_ticks) FILTER (WHERE ts_minute > now() - interval '15 min') AS ok_15m,
       sum(fail_ticks) FILTER (WHERE ts_minute > now() - interval '15 min') AS fail_15m
  FROM silver.plc_link_minutes GROUP BY 1, 2 ORDER BY 1, 2;
