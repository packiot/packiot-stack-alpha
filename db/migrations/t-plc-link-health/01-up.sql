-- t-plc-link-health — per-PLC connection health from the edge reader (2026-10-01)
--
-- Before this, the box reader posted NOTHING when a PLC connect/read failed, so
-- "line stopped", "PLC unreachable" and "box dead" reached the cloud as the same
-- silence and the count-silence deriver minted stops for all three (Bispharma
-- L58: a 15-day phantom stop). The reader now attaches link {ok, err, ms} to every
-- scan's /v1/tags envelope (tags: [] on a failure); the shared sparkplug-agent
-- aggregates it into one row per tenant × endpoint × minute here.
--
-- Reading the table (policy agreed 2026-10-01 — availability has three states):
--   ok_ticks > 0                       → PLC was read: running/stopped are real.
--   only fail_ticks                    → NO DATA (PLC unreachable).
--   no row, after the endpoint's first → NO DATA (box/reader/uplink dead — the
--   row ever                             reader spools + replays uplink outages
--                                        with their original scan_ts, so only a
--                                        dead box leaves a permanent hole).
-- Endpoint → equipment comes from the client descriptor's tag maps
-- (silver.plc_endpoint_equipment). Additive + idempotent; apply BEFORE the agent.
BEGIN;

CREATE TABLE IF NOT EXISTS silver.plc_link_minutes (
    id_enterprise  integer     NOT NULL,
    endpoint       text        NOT NULL,
    ts_minute      timestamptz NOT NULL,
    ok_ticks       integer     NOT NULL DEFAULT 0,
    fail_ticks     integer     NOT NULL DEFAULT 0,
    last_error     text,
    max_latency_ms integer,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id_enterprise, endpoint, ts_minute)
);
SELECT create_hypertable('silver.plc_link_minutes', 'ts_minute',
                         chunk_time_interval => interval '7 days', if_not_exists => true);

COMMENT ON TABLE silver.plc_link_minutes IS
  'PLC connection health per tenant × reader endpoint × UTC minute, from the edge reader''s link report (sparkplug-agent linkhealth). ok_ticks>0 = PLC read OK that minute; only fail_ticks, or no row after the endpoint''s first row, = NO DATA (excluded from availability, shown as coverage).';
COMMENT ON COLUMN silver.plc_link_minutes.endpoint IS 'Reader endpoint name = client descriptor plc.endpoints[].name (one PLC).';
COMMENT ON COLUMN silver.plc_link_minutes.ok_ticks IS 'Scans in this minute that connected and read the PLC.';
COMMENT ON COLUMN silver.plc_link_minutes.fail_ticks IS 'Scans in this minute whose connect/read failed (last_error keeps the latest reason).';

-- Which equipment each reader endpoint (PLC) feeds, straight from the client
-- descriptor's tag maps (plc.s7_tag_map / plc.modbus_tag_map / any *_tag_map).
CREATE OR REPLACE VIEW silver.plc_endpoint_equipment AS
SELECT DISTINCT cd.id_enterprise,
       m->>'endpoint'              AS endpoint,
       (m->>'id_equipment')::bigint AS id_equipment
  FROM core.client_descriptors cd
 CROSS JOIN LATERAL jsonb_each(COALESCE(cd.descriptor->'plc', '{}'::jsonb)) AS p(k, v)
 CROSS JOIN LATERAL jsonb_array_elements(
           CASE WHEN p.k LIKE '%tag_map' AND jsonb_typeof(p.v) = 'array' THEN p.v ELSE '[]'::jsonb END) AS m
 WHERE m ? 'endpoint' AND m ? 'id_equipment';

COMMENT ON VIEW silver.plc_endpoint_equipment IS
  'Reader endpoint (PLC) → id_equipment, from core.client_descriptors plc.*_tag_map entries.';

GRANT SELECT ON silver.plc_link_minutes, silver.plc_endpoint_equipment TO readapi_ro;

COMMIT;
