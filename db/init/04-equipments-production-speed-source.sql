-- 04-equipments-production-speed-source.sql — provisional ideal-speed marker.
--
-- Adds equipments.production_speed_source, the provenance flag that makes the
-- provisional ideal-speed inference (oeecloud-worker internal/rollup/inferspeed.go,
-- PROVISIONAL_SPEED_INFERENCE_ENABLED) safe to run against a live equipments row.
--
-- WHY A MARKER (the only-fill-provisional guardrail). A counters-only tenant
-- (bispharma) has no PLC param 30701 and no nameplate, so equipments.production_speed
-- is NULL and the rollup's ideal_speed COALESCE chain (hour.go / shift.go end in
-- `equipments.production_speed`) can't compute Performance. The inference task fills
-- that column from observed p95 good-count throughput. But once a CS engineer later
-- loads the REAL nameplate, inference must NEVER clobber it. The source column is the
-- discriminator: the UPSERT sets 'inferred' and only overwrites rows where the source
-- IS NULL (never inferred, never confirmed) OR already 'inferred'. A row marked
-- 'client' is a confirmed nameplate and is left untouched forever.
--
--   NULL       — never inferred, never client-confirmed (default; inference may fill)
--   'inferred' — self-inferred provisional value (inference may overwrite)
--   'client'   — CS-confirmed nameplate (inference NEVER touches)
--
-- Reference-plane table: equipments lives in `public` on BOTH the main DB and
-- packiot_analytics (RefSchema=public in flows.Standard), and refsync mirrors it
-- main->shadow via SELECT * so the new column propagates automatically once it
-- exists on both. Apply this ALTER to public.equipments on every DB that runs the
-- rollup (main + packiot_analytics). Idempotent — safe to re-run.
--
-- NOTE: db/init/ runs ONCE on a fresh local-dev Postgres boot (see README). For an
-- already-provisioned staging/prod/shadow DB this file does NOT auto-run; apply the
-- ALTER below manually (or via the edge-node-red migration path) BEFORE enabling
-- PROVISIONAL_SPEED_INFERENCE_ENABLED, else the inference UPSERT errors on the
-- missing column. The task ships default OFF, so nothing breaks until you opt in.

ALTER TABLE public.equipments
    ADD COLUMN IF NOT EXISTS production_speed_source text;

COMMENT ON COLUMN public.equipments.production_speed_source IS
    'Provenance of production_speed: NULL=unset, ''inferred''=provisional (inferspeed.go), ''client''=confirmed nameplate (never auto-overwritten).';
