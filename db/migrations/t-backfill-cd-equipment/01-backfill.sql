-- t-backfill-cd-equipment
--
-- Populates cd_equipment at the source. It is NULL for whole tenants on the new
-- stack (ent 3/5/119 = 100% null; 272 active rows total) — an onboarding/migration
-- gap. The csadmin form requires it (schema min(1)) but the field is disabled, so
-- editing ANY such equipment was silently un-saveable (csadmin#109 self-heals it on
-- edit by deriving from the name; this fills it everywhere so it's correct at rest).
--
-- Derivation matches csadmin's cleanCode(nm_equipment) EXACTLY: upper-case, every
-- run of non-[A-Z0-9] → '_', trim leading/trailing '_'. No accented names exist
-- across the null-cd set (verified), so no unaccent is needed. Only fills empties,
-- never rewrites an existing code (which the create path also refuses to rewrite,
-- to protect any packml routing identity).
--
-- SAFETY: on core.equipments (analytics — the live source edge-api reads/writes)
-- the only trigger is set_updated_at; there is NO "Create packml topics" trigger
-- here (that lives on legacy packiot), so this does NOT regenerate packml_register
-- / change SparkPlug routing. cd_equipment has a plain (non-unique) index, so the
-- resulting duplicate codes for identically-named sibling machines are allowed and
-- harmless (routing keys on packml_register, not cd_equipment).

BEGIN;

UPDATE core.equipments
SET cd_equipment = trim(both '_' from regexp_replace(upper(trim(nm_equipment)), '[^A-Z0-9]+', '_', 'g'))
WHERE (cd_equipment IS NULL OR cd_equipment = '')
  AND nm_equipment IS NOT NULL
  AND trim(nm_equipment) <> '';

COMMIT;
