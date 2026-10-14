-- verify t-sandbox-reflect-line-roles — read-only.
\set ON_ERROR_STOP 1
BEGIN TRANSACTION READ ONLY;
DO $v$
DECLARE def text := pg_get_functiondef((SELECT oid FROM pg_proc WHERE pronamespace='ops'::regnamespace AND proname='sandbox_reflect'));
BEGIN
  IF position($c$'net_machine', x.net_machine + %1$s$c$ IN def) = 0 OR position($c$'gross_machine', x.gross_machine + %1$s$c$ IN def) = 0
     OR position($c$'scrap_machine', x.scrap_machine + %1$s$c$ IN def) = 0 THEN
    RAISE EXCEPTION 'V1: sandbox_reflect does not remap the line meter roles';
  END IF;
  RAISE NOTICE 'OK: sandbox_reflect remaps gross/net/scrap_machine';
END $v$;
-- V2 (after the next heal): no twin line points a role at another tenant's machine
SELECT 'V2 cross-tenant twin roles', count(*) FROM core.equipments l
  CROSS JOIN LATERAL (VALUES (l.gross_machine), (l.net_machine), (l.scrap_machine)) r(id)
  JOIN core.equipments m ON m.id_equipment = r.id
 WHERE l.id_enterprise = 2000003 AND l.tp_equipment = 3 AND m.id_enterprise <> l.id_enterprise;
ROLLBACK;
