-- t237 Phase 1 (stream-engine Dest per-schema refactor) — CONTRACT (task #237).
--
-- Precondition: the stream-engine per-schema refactor is DEPLOYED. flows.Dest now
-- carries per-layer schema knobs (SilverSchema/GoldSchema/GrainSchema/AppSchema in
-- addition to EvSchema/RefSchema), and the two app tables are referenced at their
-- real home `app`:
--   - reports/boxes_adapter.go   `FROM {AppSchema}.label_formats`   (AppSchema=app)
--   - pocontrol/{events_justify,setup_userlog}.go `INSERT INTO {appSchema}.user_logs`
--     (route.app=app on the refactored+analyticsPool staging route)
-- No other consumer references public.label_formats / public.user_logs — before the
-- P-app.2 `06` restore (which existed ONLY for the public-qualified stream-engine
-- Dest), neither shim existed and every other consumer resolved via search_path→app.
--
-- This reverts db/migrations/t237-app-schema/06-restore-stream-engine-public-shims.sql.
-- Apply AFTER the stream-engine deploy is healthy (gate: 0 42P01 on boxes/pocontrol,
-- boxes tick clean, ingest healthy).

DROP VIEW IF EXISTS public.label_formats;
DROP VIEW IF EXISTS public.user_logs;
