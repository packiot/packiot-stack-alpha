-- t-adr0061-p3d-bindings-backfill — ADR-0061 key-first: EVERY active equipment has a declared identity.
--
-- The P0 backfill (2026-10-07) minted keys for equipment that had an active ROUTING row (packml_register), so an
-- equipment with no topic — e.g. a line created before P0b that never got a register row — stayed keyless
-- (staging: enterprise 120, line 990102). Since then edge-api mints at create/reactivate (ensureBindingCtes), so
-- only pre-P0b equipment can be in this state. Identity must not depend on a topic: this gives every active
-- equipment an active binding, with exactly edge-api's semantics:
--   active binding exists → nothing (a key is never regenerated);
--   only inactive bindings → re-activate the NEWEST (a reactivated equipment keeps its key);
--   none at all           → mint a fresh opaque key.
-- Idempotent; the partial unique index (one active binding per equipment) is the race guard.
-- PROD PROMOTION: run this (not a routing-row backfill) when populating core.device_bindings on prod.

\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '3s';

WITH target AS (
  SELECT e.id_equipment, e.id_enterprise FROM core.equipments e
   WHERE e.active
     AND NOT EXISTS (SELECT 1 FROM core.device_bindings a WHERE a.id_equipment = e.id_equipment AND a.active)
), rebound AS (
  UPDATE core.device_bindings b SET active = true
    FROM target t
   WHERE b.id_equipment = t.id_equipment
     AND b.id_device_binding = (SELECT max(x.id_device_binding) FROM core.device_bindings x WHERE x.id_equipment = t.id_equipment)
  RETURNING b.id_equipment
), minted AS (
  INSERT INTO core.device_bindings (id_enterprise, id_equipment, device_key)
  SELECT t.id_enterprise, t.id_equipment, 'dk_' || replace(gen_random_uuid()::text, '-', '')
    FROM target t
   WHERE NOT EXISTS (SELECT 1 FROM core.device_bindings x WHERE x.id_equipment = t.id_equipment)
  RETURNING id_equipment
)
SELECT 'rebound', count(*) FROM rebound UNION ALL SELECT 'minted', count(*) FROM minted;

COMMIT;
