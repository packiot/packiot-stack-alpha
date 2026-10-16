-- t-enterprise-codes — a stable, human-readable code per enterprise (2026-10-15).
--
-- WHY
-- Enterprises are identified everywhere by surrogate ids (5, 2000003): ~15 compose/env literals
-- and ~687 `id_enterprise = <n>` literals in SQL/scripts. The display name (nm_enterprise) is NOT
-- a usable key: it changes (ent 5 is 'Bispharma-Staging' today, 'Bispharma' on prod and
-- 'Bispharma (mirror)' on staging after the go-live). A code is the third identifier:
--   id_enterprise  surrogate PK, joins/FKs/RLS      never changes, meaningless
--   nm_enterprise  display name                     changes freely
--   code           human + config key              never changes, portable across environments
-- The same customer keeps the same code in dev, staging and prod even when ids differ
-- (CPACK = 3, its sandbox twin = 2000003 → 'cpack' and 'sandbox-cpack').
--
-- RULES (decided by the user, 2026-10-15)
--   * lowercase ASCII, digits and single dashes; accents are removed ('São' → 'sao');
--   * a code is NEVER reused: enterprises are deactivated (active=false), not deleted, so the
--     UNIQUE constraint below also blocks codes of inactive enterprises — no extra logic needed;
--   * a code never changes once set (trigger below);
--   * a sandbox/twin tenant gets its OWN code ('sandbox-cpack'), not an environment flag.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;

-- slugify: free text → a valid code. Used to SUGGEST a code for a new enterprise (CS Admin
-- onboarding) and as the reference the CHECK below agrees with.
-- NOTE: public.unaccent(text) is only STABLE (its dictionary could change), so it cannot be used
-- inside a CHECK or an index directly. The usual fix is an IMMUTABLE wrapper that pins the
-- dictionary: public.unaccent('public.unaccent', s).
CREATE OR REPLACE FUNCTION core.slugify_enterprise_code(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS $fn$
  -- 'Bispharma-Staging' → 'bispharma-staging'; 'Indústria São José' → 'industria-sao-jose';
  -- '  CPACK  (mirror) ' → 'cpack-mirror'; 'Ação & Cia. Ltda.' → 'acao-cia-ltda'.
  -- Order matters: unaccent BEFORE the [^a-z0-9] filter, or 'ç'/'ã' would become dashes
  -- ('a-o'); collapse runs with '+' so ' & ' is one dash, then trim edge dashes.
  SELECT btrim(
           regexp_replace(lower(public.unaccent('public.unaccent'::regdictionary, p_text)),
                          '[^a-z0-9]+', '-', 'g'),
           '-')
$fn$;

ALTER TABLE core.enterprises ADD COLUMN IF NOT EXISTS code text;

-- Backfill: chosen by hand, NOT slugified from the names — names carry environment suffixes
-- ('-Staging') that must not leak into a portable code.
UPDATE core.enterprises e SET code = v.code
  FROM (VALUES (1, 'staging'), (2, 'simulator-corp'), (3, 'cpack'), (4, 'incoplast'), (5, 'bispharma'),
               (119, 'bisnago'), (120, 'ops-test'), (1000000, 'packiot-admin'), (2000003, 'sandbox-cpack')) v(id, code)
 WHERE e.id_enterprise = v.id AND e.code IS NULL;

-- Any enterprise not in the list above (another environment) gets its slugified name.
UPDATE core.enterprises SET code = core.slugify_enterprise_code(nm_enterprise) WHERE code IS NULL;

ALTER TABLE core.enterprises ALTER COLUMN code SET NOT NULL;
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_code_key;
ALTER TABLE core.enterprises ADD CONSTRAINT enterprises_code_key UNIQUE (code);   -- covers inactive rows too
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_code_format;
ALTER TABLE core.enterprises ADD CONSTRAINT enterprises_code_format
  CHECK (code ~ '^[a-z0-9]+(-[a-z0-9]+)*$' AND length(code) BETWEEN 2 AND 63);

-- Immutable once set.
CREATE OR REPLACE FUNCTION core.enterprises_code_immutable() RETURNS trigger LANGUAGE plpgsql AS $t$
BEGIN
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    RAISE EXCEPTION 'enterprises.code is immutable (% → %); codes are never renamed or reused', OLD.code, NEW.code
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $t$;
DROP TRIGGER IF EXISTS enterprises_code_immutable ON core.enterprises;
CREATE TRIGGER enterprises_code_immutable BEFORE UPDATE OF code ON core.enterprises
  FOR EACH ROW EXECUTE FUNCTION core.enterprises_code_immutable();

-- ent('bispharma') → 5, for ad-hoc SQL and scripts: WHERE id_enterprise = ent('bispharma').
-- STABLE (reads a table); raises on an unknown code instead of silently matching nothing.
CREATE OR REPLACE FUNCTION public.ent(p_code text) RETURNS integer LANGUAGE plpgsql STABLE AS $e$
DECLARE v integer;
BEGIN
  SELECT id_enterprise INTO v FROM core.enterprises WHERE code = p_code;
  IF v IS NULL THEN RAISE EXCEPTION 'unknown enterprise code %', p_code USING ERRCODE = 'no_data_found'; END IF;
  RETURN v;
END $e$;

COMMENT ON COLUMN core.enterprises.code IS
  'Stable human/config key (t-enterprise-codes): lowercase ascii slug, unique across active AND inactive enterprises, immutable, never reused. Prefer it over id_enterprise in config, scripts and logs.';
COMMIT;
