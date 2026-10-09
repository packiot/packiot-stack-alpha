-- ─────────────────────────────────────────────────────────────────────────────
-- F3 CUTOVER FIX 3 (MED): legacy-replicator drops HOTMADAG/FLEXO (+POLYTYPE1/
-- SLEEVE1) downtimes — "downtime-event-created: unresolved equipment"
--
-- Symptom: analytics-sync (legacy-replicator, packiot40 ent-1 → F3 ent-3) logs
-- a steady stream of `unresolved equipment legacy_equipment=99` (HOTMADAG) and
-- `=557` (FLEXO) — plus 110 (POLYTYPE1) and 763 (SLEEVE1). Their base downtime
-- rows never land in F3 (61 events / 48h dropped).
--
-- ORIGINAL DIAGNOSIS (in the task) WAS WRONG: it assumed staging ent-3 was
-- seeded with only single-segment topics and the doubled twins were MISSING.
-- They are NOT missing — equipments 87/104/99/107 (the tp=1 machine twins) and
-- their doubled packml_register rows (CPACK/SC/CELULA1/HOTMADAG/HOTMADAG, etc.)
-- all exist and are active.
--
-- ACTUAL ROOT CAUSE: each of those machine twins ALSO carries a MALFORMED
-- sandbox-simulator packml_register row `CPACK_STAGING/SC/CELULAn//` (double
-- slash, empty equipment leaf). The resolver (resolver.go / baseTopicByEquip)
-- keys legacy→staging by the SHORTEST non-Admin/Status packml_topic per
-- equipment, enterprise-prefix stripped + uppercased. The junk topic is SHORTER
-- than the real doubled topic, so it wins:
--     id 87  : CPACK_STAGING/SC/CELULA1//  (len 26)  <  CPACK/SC/CELULA1/HOTMADAG/HOTMADAG (34)
--   → normalized base = "SC/CELULA1//"  which matches NOTHING on the legacy side
--     (legacy 99 normalizes to "SC/CELULA1/HOTMADAG/HOTMADAG").
-- Same shape for 104 (FLEXO), 99 (POLYTYPE1), 107 (SLEEVE1). id 78 (L10-PTH)
-- also has the junk row but its REAL topic is shorter, so it still resolves —
-- deleting the junk there is pure hygiene.
--
-- Fix: delete the 5 machine-level (id_equipment IS NOT NULL) CPACK_STAGING junk
-- rows so the resolver falls back to the correct doubled topic, which DOES match
-- the legacy base topic. (The 12 id_equipment-NULL CPACK_STAGING hierarchy junk
-- rows are cleaned separately in f3-packml-register-hygiene.sql.)
--
-- Requires a legacy-replicator restart afterward: the resolver map is built ONCE
-- at startup and cached. `starts_with()` is used (not LIKE) so the literal
-- underscore in "CPACK_STAGING" is not treated as a wildcard.
-- Idempotent: re-running deletes 0 rows.
-- ─────────────────────────────────────────────────────────────────────────────

DELETE FROM packml_register
 WHERE id_enterprise = 3
   AND id_equipment IS NOT NULL
   AND starts_with(packml_topic, 'CPACK_STAGING');
