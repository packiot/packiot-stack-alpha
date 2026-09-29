-- Rollback for t-ent5-area-day-begin-align: restore the ent 5 areas' week_begin/day_begin
-- from the backup taken by 01-up.sql.
BEGIN;
UPDATE core.areas a
   SET week_begin = (b.row->>'week_begin')::int,
       day_begin  = (b.row->>'day_begin')::int
  FROM ops._bkp_ent5_csadmin_fixes_20260929 b
 WHERE b.kind = 'area' AND (b.row->>'id_area')::int = a.id_area AND a.id_enterprise = 5;
COMMIT;
