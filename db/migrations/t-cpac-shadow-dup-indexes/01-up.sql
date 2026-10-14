-- t-cpac-shadow-dup-indexes — drop the two redundant UNIQUE indexes on
-- silver.equipment_events_cpac_shadow (CPAC deriver shadow table, ADR-0010 §10.4).
--
-- WHY (staging, 2026-10-14): the table carries THREE identical unique btree indexes on
-- (id_equipment, ts_event), 40 MB each:
--   equipment_events_cpac_shadow_pkey                       backs PRIMARY KEY  → KEEP
--   equipment_events_cpac_shadow_key                        plain unique index → DROP
--     (created "defensively" by docs/adr/reference/migrations/0010-104-cpac-events-shadow.sql)
--   equipment_events_cpac_shadow_id_equipment_ts_event_idx  plain unique index → DROP
--     (copied from the source's equipment_events_pk by CREATE TABLE … LIKE … INCLUDING ALL)
-- Neither dropped index backs a constraint (pg_constraint.conindid: only _pkey), so plain
-- DROP INDEX works (no ALTER TABLE … DROP CONSTRAINT). Nothing names them: no
-- `ON CONFLICT ON CONSTRAINT`, no FK, no function body (git grep + pg_proc, 2026-10-14). The
-- deriver's `ON CONFLICT (id_equipment, ts_event)` infers EVERY matching unique index as an
-- arbiter, so today each upsert probes three indexes and each insert maintains three; after
-- this, the PK alone.
--
-- NOT the live silver.equipment_events: it has the same parent-level duplicate
-- (equipment_events_pk vs equipment_events_pkey), but that one is a hypertable and the drop
-- was already tried and refused (TimescaleDB dispatches it onto the chunk PK constraint
-- indexes; docs/plans/silver-bronze-column-redesign.md, "duplicate PK index on a
-- hypertable"). The parent-only index has no chunk children, so it costs no storage there.
--
-- NON-TRANSACTIONAL: DROP INDEX CONCURRENTLY cannot run inside a transaction block and takes
-- one index per statement. Run with psql WITHOUT -1/--single-transaction. It waits for the
-- transactions that may use the index (the deriver's tick, ≤ a few seconds); it never blocks
-- the deriver's reads or writes. If it is interrupted (lock_timeout), the index can be left
-- INVALID: re-run this file; IF EXISTS makes it idempotent and finishes the drop.
\set ON_ERROR_STOP 1
SET lock_timeout = '30s';
DROP INDEX CONCURRENTLY IF EXISTS silver.equipment_events_cpac_shadow_key;
DROP INDEX CONCURRENTLY IF EXISTS silver.equipment_events_cpac_shadow_id_equipment_ts_event_idx;
