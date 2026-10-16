-- ─────────────────────────────────────────────────────────────────────────────
-- F3 CUTOVER FIX 5 (LOW): packml_register hygiene
--
-- Task premise was "13 INACTIVE rows pointing at deleted equipment". On current
-- live F3 there are ZERO such orphans — 0 ACTIVE and 0 INACTIVE packml_register
-- rows reference a non-existent equipments row (verified via NOT EXISTS join).
-- Nothing to clean on that front.
--
-- The actual packml_register pollution is the CPACK_STAGING sandbox-simulator
-- artifact: a tree of malformed topics (trailing/double slash, empty leaf) that
-- leaked into ent-3. The 5 rows that carry an id_equipment are removed in
-- f3-legacy-replicator-cpack-staging-pollutants.sql (they break the legacy
-- resolver). This file removes the remaining 12 id_equipment-NULL CPACK_STAGING
-- hierarchy junk rows, e.g.:
--   CPACK_STAGING, CPACK_STAGING/SC, CPACK_STAGING/SC/CELULA1,
--   CPACK_STAGING/SC/CELULA1/ , CPACK_STAGING/SC/LINHAS/ , ...
--
-- LEFT ALONE (per task): the 7 legitimate active id_equipment-NULL hierarchy/
-- aggregation topics on the real `CPACK/` prefix (CPACK, CPACK/SC,
-- CPACK/SC/CELULA1|CELULA2|CELULA9|LINHAS) plus the CPACK / CPACK-Staging
-- enterprise-root rows. None of those, nor any removed row, is a leaf machine
-- topic (verified: no doubled `/X/X` leaf among the NULL-id set).
--
-- `starts_with()` (not LIKE) so the literal underscore in "CPACK_STAGING" is not
-- a wildcard, and "CPACK-Staging" (hyphen) is never matched. Idempotent.
-- ─────────────────────────────────────────────────────────────────────────────

DELETE FROM packml_register
 WHERE id_enterprise = 3
   AND id_equipment IS NULL
   AND starts_with(packml_topic, 'CPACK_STAGING');
