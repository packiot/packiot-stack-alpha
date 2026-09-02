-- ── capture_observations — ADR-0045 Phase-2b live-capture evidence table ──────
--
-- The sparkplug-agent WRITES this table when a tenant is in the OBSERVE posture
-- (client_descriptors.status = 'captured'); edge-api (Phase-2b-api) READS it to
-- build the DQ report and drive the confirm step that promotes a descriptor's
-- count-index entries from `inferred` to `confirmed`.
--
-- It is a SHARED, agent-written / edge-api-read table — the same ownership shape
-- as packml_register (agent-side writer, control-plane reader). Count indices are
-- PLC facts that are OBSERVED, not typed (ADR-0045 §2.4b): each row records that
-- an equipment `topic` actually emitted count index `count_index` on a live tee,
-- with first/last-seen bookends and a hit counter.
--
-- Upsert key is (id_enterprise, topic, count_index): one row per observed count
-- channel. Repeats bump last_seen_ts + observed_count; first_seen_ts is pinned to
-- the earliest sighting. Best-effort DQ evidence — never on the hot data path.
--
-- Like the rest of db/init/, this file is the DEV-ONLY bootstrap DDL (mounted by
-- compose.development.yml on first Postgres boot). Staging/prod apply the same
-- CREATE via their own migration lineage (edge-node-red), exactly as packml_register
-- is managed — the DDL below is the contract both environments must match.

CREATE TABLE IF NOT EXISTS capture_observations (
    id_capture_observation  BIGSERIAL PRIMARY KEY,
    id_enterprise           INTEGER     NOT NULL,
    topic                   VARCHAR     NOT NULL,   -- equipment topic (packml name minus the count leaf)
    count_index             INTEGER     NOT NULL,   -- the PLC channel index observed in .../<IDX>/Unit
    metric_suffix           VARCHAR     NOT NULL,   -- the count leaf template, e.g. /Admin/ProdConsumedCount/{idx}/Unit
    first_seen_ts           TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
    observed_count          BIGINT      NOT NULL DEFAULT 0,
    UNIQUE (id_enterprise, topic, count_index)
);

-- The Phase-2b-api report reads all observations for one tenant.
CREATE INDEX IF NOT EXISTS idx_capture_obs_enterprise ON capture_observations (id_enterprise);
