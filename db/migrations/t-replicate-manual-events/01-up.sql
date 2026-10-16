-- t-replicate-manual-events — provenance for the legacy-replicator MANUAL-event
-- reconciler (services/analytics-sync/internal/replicate/manual_reconcile.go).
--
-- The reconciler mirrors legacy packiot40 equipment_events_man into
-- silver.equipment_events_man (CPACK ent 1 -> 3, and the sandbox twin 2000003)
-- and DELETES analytics rows that no longer exist in legacy — but only rows it
-- OWNS. Ownership = a row in ops.legacy_manual_event_link. The reconciler also
-- creates this table itself (CREATE ... IF NOT EXISTS, identical DDL) and links
-- every row it inserts or finds sitting exactly on a legacy (id_equipment,
-- ts_event) key; this migration adds the one thing it cannot infer: the
-- replay-era ORPHANS whose legacy twin moved or never existed.
--
-- SEED EVIDENCE (staging, 2026-09-29): every ent-3 manual row since 2026-08-01
-- is forced_creation_system=true with last_update in [2026-08-21 21:14,
-- 2026-09-12 13:48] — i.e. written by the legacy-replicator's user_logs handlers
-- (they set forced=true; its cold start ran 2026-08-21 21:14; t261e dropped the
-- public shim they wrote through on 2026-09-13). 356 such rows per tenant. No
-- new-stack author in that span: identity.user_logs has no ent-3
-- manual-event-*/event-splitted rows after 2026-08-13, and new-stack writers
-- (edge-api create, stream-engine pocontrol) leave forced_creation_system NULL.
-- The sandbox 2000003 carries the same 356 rows (cloned from ent 3).
-- Orphans among them: ~130 zero-duration rows 08-14..08-27 (the old twin
-- event-splitted handler wrote split SEGMENTS into equipment_events_man — fixed
-- in handlers.go, rows never cleaned) + the FLEXO 09-08 20:23 row whose legacy
-- twin moved to 20:28. Seeded with legacy_id NULL; the reconciler re-links any
-- that match a legacy key and deletes the rest inside its lookback.
--
-- Idempotent. Rollback: rollback.sql (drops the table; the reconciler must be
-- disabled first or it recreates it empty — then it can no longer delete).
CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.legacy_manual_event_link (
	id_equipment_event        integer     PRIMARY KEY,
	dst_enterprise            integer     NOT NULL,
	legacy_id_equipment_event bigint,
	linked_at                 timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS legacy_manual_event_link_ent_legacy_idx
	ON ops.legacy_manual_event_link (dst_enterprise, legacy_id_equipment_event);

COMMENT ON TABLE ops.legacy_manual_event_link IS
  'Provenance of silver.equipment_events_man rows mirrored from legacy packiot40 by the legacy-replicator manual-event reconciler. A row here = owned by the reconciler (it may update/move/delete it); rows absent here (new-stack edge-api/operator authored) are never deleted by it. legacy_id_equipment_event NULL = replay-era row seeded by t-replicate-manual-events (legacy id unknown). No FK by design (TRUNCATE/sandbox re-clone of the silver table must not cascade); dangling links are pruned each pass.';

INSERT INTO ops.legacy_manual_event_link (id_equipment_event, dst_enterprise, legacy_id_equipment_event)
SELECT m.id_equipment_event, m.id_enterprise, NULL
  FROM silver.equipment_events_man m
 WHERE m.id_enterprise IN (3, 2000003)
   AND m.forced_creation_system IS TRUE
   AND m.last_update >= '2026-08-21 21:00:00+00'
   AND m.last_update <  '2026-09-13 00:00:00+00'
ON CONFLICT (id_equipment_event) DO NOTHING;
