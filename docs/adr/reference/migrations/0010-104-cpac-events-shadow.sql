-- 0010-104-cpac-events-shadow.sql — ADR-0010 §10.4 GAP-1: the CPAC stop
-- deriver's DARK shadow comparison table. NOT YET APPLIED — apply per flow
-- schema ONLY when you flip CPAC_EVENT_DERIVATION_ENABLED to run the comparator.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHY A SEPARATE TABLE (not equipment_events itself)
-- ═══════════════════════════════════════════════════════════════════════════
-- For CPACK (status_type=0) the LIVE equipment_events is already owned by two
-- writers we must not fight:
--   1. the mirror-worker FanoutEventRow — it fans prod's authoritative CPAC
--      downtime events into the shadow flows; those rows ARE the comparator
--      ground truth.
--   2. operators — who justify/split/trim via edge-api.
-- So the DARK deriver writes to THIS separate table. Result: (a) deploying the
-- deriver flag-off is byte-identical to today (it's a whole new job writing a
-- whole new table); (b) the comparator is a clean two-table diff
-- (equipment_events_cpac_shadow  vs  equipment_events filtered to CPACK).
--
-- The clone carries the FULL equipment_events shape (INCLUDING ALL) so the
-- never-clobber-a-human-edit guards (cd_category / txt_downtime_notes /
-- planned_downtime / change_over / idle / forced_creation_system) are exercised
-- exactly as they will run against the real table on eventual enablement — at
-- which point the plan is: populate per-equipment stop_threshold_time, retarget
-- CPAC_EVENT_TARGET_TABLE=equipment_events, and disable FanoutEventRow for CPACK.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- APPLY — run in EACH flow's EvSchema (F3 = packiot_shadow.public; add
-- shadow_go_port only if F2 is still live). Idempotent.
-- ═══════════════════════════════════════════════════════════════════════════

-- F3 (packiot_shadow database, public schema):
--   psql "$F3_URL" -f 0010-104-cpac-events-shadow.sql
CREATE TABLE IF NOT EXISTS public.equipment_events_cpac_shadow
    (LIKE public.equipment_events INCLUDING ALL);

-- Guarantee the idempotency key exists even if the source's UNIQUE was not
-- captured by INCLUDING ALL (defensive — the deriver's ON CONFLICT needs it).
CREATE UNIQUE INDEX IF NOT EXISTS equipment_events_cpac_shadow_key
    ON public.equipment_events_cpac_shadow (id_equipment, ts_event);

-- The derived rows carry forced_creation_system=false explicitly; make the
-- column NOT-NULL-safe for the human-touched guard (NULL would read as "not
-- protected", which is the correct default for a fresh derived row).
ALTER TABLE public.equipment_events_cpac_shadow
    ALTER COLUMN forced_creation_system SET DEFAULT false;

-- Optional but recommended: keep the shadow table lean — it only needs the
-- deriver's recompute window plus a comparison horizon. A 7-day retention keeps
-- it from growing unbounded during a long bake. (Requires TimescaleDB; skip if
-- the clone did not inherit hypertable-ness — a plain table is fine for a bake.)
-- SELECT add_retention_policy('public.equipment_events_cpac_shadow', INTERVAL '7 days', if_not_exists => true);

-- ── ROLLBACK ────────────────────────────────────────────────────────────────
-- DROP TABLE IF EXISTS public.equipment_events_cpac_shadow;
