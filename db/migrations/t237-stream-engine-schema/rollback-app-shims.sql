-- t237 Phase 1 — ROLLBACK of 01-contract-app-shims.sql (task #237).
-- Re-restores the auto-updatable public shim views over the app bases. Use if the
-- stream-engine per-schema refactor is reverted (Dest still public-qualifies these),
-- mirroring t237-app-schema/06-restore-stream-engine-public-shims.sql.

CREATE OR REPLACE VIEW public.label_formats AS SELECT * FROM app.label_formats;
CREATE OR REPLACE VIEW public.user_logs     AS SELECT * FROM app.user_logs;
