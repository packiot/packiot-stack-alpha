-- ─────────────────────────────────────────────────────────────────────────────
-- F3 CUTOVER FIX 1 (HIGH): capture_observations table missing on packiot_analytics
--
-- Symptom: onboarding Capture report endpoint
--   GET /api/onboarding/capture/report?idEnterprise=<n>  → HTTP 500
--   because to_regclass('public.capture_observations') = NULL on F3.
--
-- Root cause: the ADR-0045 Phase-2b live-capture evidence table exists in the
-- dev bootstrap DDL (db/init/04-capture-observations.sql) but was never applied
-- to the staging/prod packiot_analytics lineage (same class of drift as any
-- agent-written/control-plane-read table that skips the migration path).
--
-- Fix: apply the exact contract DDL. Idempotent (CREATE ... IF NOT EXISTS).
-- Mirror of db/init/04-capture-observations.sql — keep the two in sync.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS capture_observations (
    id_capture_observation  BIGSERIAL PRIMARY KEY,
    id_enterprise           INTEGER     NOT NULL,
    topic                   VARCHAR     NOT NULL,
    count_index             INTEGER     NOT NULL,
    metric_suffix           VARCHAR     NOT NULL,
    first_seen_ts           TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
    observed_count          BIGINT      NOT NULL DEFAULT 0,
    UNIQUE (id_enterprise, topic, count_index)
);

CREATE INDEX IF NOT EXISTS idx_capture_obs_enterprise ON capture_observations (id_enterprise);
