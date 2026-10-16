-- t237 P-app.2 tail — RESTORE two public shim views stranded by P-app.1 (task #237).
--
-- ROOT CAUSE: stream-engine's flows.Dest hardcodes EvSchema="public" AND RefSchema="public"
-- (services/stream-engine/internal/flows/flows.go:52,57). It does NOT resolve these tables via
-- search_path — it explicitly qualifies to `public.<t>` through `%[1]s`/`%[2]s` format args.
-- The medallion split deliberately KEPT `public` shim views (public.equipment_values→silver, …)
-- precisely so this public-qualified engine keeps working. P-app.1 moved `label_formats` and
-- `user_logs` public→app AND dropped their public shims at contract — but stream-engine still
-- references them public-qualified:
--   - reports/boxes_adapter.go:38   `FROM %[2]s.label_formats`   (RefSchema=public) — LIVE
--       failing: "boxes pass failed: load label_formats: relation public.label_formats does not
--       exist" every 5-min boxes tick since P-app.1's contract.
--   - pocontrol/{events_justify,setup_userlog}.go `INSERT INTO %[1]s.user_logs` (EvSchema=public)
--       — LATENT: fires only on a PO justify/setup event flowing through the Go pocontrol port.
--
-- The reorg's §6 premise "search_path absorbs stream-engine except a finite Go-pin set" does NOT
-- hold for the public-qualified Dest. Until stream-engine's boxes/pocontrol are re-pointed to
-- `app` (a stream-engine code lift + deploy — owed at P-core when the dims RefSchema also moves;
-- note label_formats[app] and equipments[core] can no longer share one RefSchema, so that lift
-- must give label_formats its own schema arg), these two public shims MUST persist.
--
-- Auto-updatable views (simple SELECT *) — INSERTs pass through to app (proven: a probe INSERT
-- through public.user_logs landed in app.user_logs, rolled back).

CREATE OR REPLACE VIEW public.label_formats AS SELECT * FROM app.label_formats;
CREATE OR REPLACE VIEW public.user_logs     AS SELECT * FROM app.user_logs;

-- ROLLBACK (only AFTER stream-engine boxes/pocontrol are re-pointed off public):
--   DROP VIEW IF EXISTS public.label_formats;
--   DROP VIEW IF EXISTS public.user_logs;
