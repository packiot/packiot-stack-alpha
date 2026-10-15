-- verify for t-enterprise-codes. label | value — the expected value is in the label. Read-only except V8
-- (inside BEGIN … ROLLBACK).
\set ON_ERROR_STOP 1
\pset pager off
SELECT 'V1 every enterprise has a valid code: 0 missing|0 invalid',
       count(*) FILTER (WHERE code IS NULL),
       count(*) FILTER (WHERE code IS NOT NULL AND code !~ '^[a-z0-9]+(-[a-z0-9]+)*$')
  FROM core.enterprises;
SELECT 'V2 codes are unique (incl. inactive): 0 duplicates', count(*) - count(DISTINCT code) FROM core.enterprises;
SELECT 'V3 slugify examples: t',
       core.slugify_enterprise_code('Bispharma-Staging')  = 'bispharma-staging'
   AND core.slugify_enterprise_code('Indústria São José') = 'industria-sao-jose'
   AND core.slugify_enterprise_code('  CPACK  (mirror) ') = 'cpack-mirror'
   AND core.slugify_enterprise_code('Ação & Cia. Ltda.')  = 'acao-cia-ltda';
SELECT 'V4 slugify is IMMUTABLE: i', provolatile FROM pg_proc WHERE oid = 'core.slugify_enterprise_code(text)'::regprocedure;
SELECT 'V5 known codes (info; staging expects cpack=3 bispharma=5 sandbox-cpack=2000003)',
       (SELECT id_enterprise FROM core.enterprises WHERE code='cpack')        AS cpack,
       (SELECT id_enterprise FROM core.enterprises WHERE code='bispharma')    AS bispharma,
       (SELECT id_enterprise FROM core.enterprises WHERE code='sandbox-cpack') AS sandbox_cpack;
SELECT 'V6 ent(''cpack'') = id of cpack (exists in every env): t',
       public.ent('cpack') = (SELECT id_enterprise FROM core.enterprises WHERE code='cpack');
DO $$ BEGIN
  PERFORM public.ent('no-such-enterprise');
  RAISE EXCEPTION 'verify: ent() did not raise on an unknown code';
EXCEPTION WHEN no_data_found THEN RAISE NOTICE 'V7 ent() raises on an unknown code: ok';
END $$;
BEGIN;
DO $$ BEGIN
  UPDATE core.enterprises SET code = code || '-x' WHERE id_enterprise = (SELECT min(id_enterprise) FROM core.enterprises);
  RAISE EXCEPTION 'verify: code rename was allowed';
EXCEPTION WHEN check_violation THEN RAISE NOTICE 'V8 code rename blocked by the trigger: ok';
END $$;
ROLLBACK;
