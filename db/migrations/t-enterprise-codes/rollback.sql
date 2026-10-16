-- rollback for t-enterprise-codes. Drops the code column and its helpers. The unaccent extension is
-- left installed (harmless, and other objects may start using it).
\set ON_ERROR_STOP 1
BEGIN;
DROP TRIGGER IF EXISTS enterprises_code_immutable ON core.enterprises;
DROP FUNCTION IF EXISTS core.enterprises_code_immutable();
DROP FUNCTION IF EXISTS public.ent(text);
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_code_format;
ALTER TABLE core.enterprises DROP CONSTRAINT IF EXISTS enterprises_code_key;
ALTER TABLE core.enterprises DROP COLUMN IF EXISTS code;
DROP FUNCTION IF EXISTS core.slugify_enterprise_code(text);
COMMIT;
