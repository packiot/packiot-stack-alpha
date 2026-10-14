-- rollback t-rls-helpers-parallel-safe: restore the exact previous attributes (STABLE, PARALLEL
-- UNSAFE, NOT LEAKPROOF, no comment). Bodies, grants and policies were never touched.
-- Needs a superuser (NOT LEAKPROOF too). Effect: parallel plans are lost again for NOBYPASSRLS roles.
\set ON_ERROR_STOP 1
BEGIN;
SET LOCAL lock_timeout = '5s';

ALTER FUNCTION public.current_tenant() STABLE PARALLEL UNSAFE NOT LEAKPROOF;
ALTER FUNCTION public.is_all_tenant()  STABLE PARALLEL UNSAFE NOT LEAKPROOF;
COMMENT ON FUNCTION public.current_tenant() IS NULL;
COMMENT ON FUNCTION public.is_all_tenant()  IS NULL;

COMMIT;
