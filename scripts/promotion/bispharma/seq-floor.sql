-- seq-floor.sql — run on packiot_next BEFORE the swap (xplant.sh phase `seqfloor`), on the prod server that still holds the
-- OLD prod DB as `packiot` (CPACK's prod history, kept for CPACK's own go-live as packiot_pre_promotion).
-- WHY (Bispharma rehearsal 2026-10-15): the clean prod starts from ONE tenant's ids. Its sequences are set to that tenant's
-- max, e.g. core.production_orders restarts at 1 because Bispharma has no POs yet — while the old DB already holds CPACK's
-- POs up to ~1.6 M. When CPACK's history is later brought into this DB, every colliding id would have to be renumbered,
-- and PO ids are referenced outside the DB (labels, legacy-replicator links, operator URLs). Raising each sequence ABOVE
-- the old DB's max for the same table/column now costs nothing and keeps CPACK's ids free.
-- Idempotent; never lowers a sequence; tables the old DB doesn't have are skipped (reported).
--
-- PRODUCTION ID BLOCK (ADR-0064, 2026-10-15): after the go-live staging mirrors production for this tenant and copies
-- production's rows WITH their ids. Staging's sequences keep minting ids for its other tenants (CPACK mirror, sandbox),
-- so a production id inside staging's range would collide there. Every sequence is therefore also floored at
-- 1,000,000,000 (staging's highest id in any reflected table is 601,633,961; invariant MR4 checks both sides forever).
-- It also closes a gap in the old-DB floor above: legacy CPACK keeps minting ids AFTER that snapshot, so CPACK's later
-- go-live could have collided with Bispharma's new production ids; above 1e9 it cannot. The knex ledger is exempt.
\set ON_ERROR_STOP 1
CREATE EXTENSION IF NOT EXISTS dblink;
DO $f$ DECLARE r record; src_t text; src_c text; old_max bigint; cur bigint; raised int := 0; skipped int := 0; blocked int := 0; have_old boolean; BEGIN
  have_old := EXISTS (SELECT 1 FROM pg_database WHERE datname = 'packiot' AND datname <> current_database());
  IF NOT have_old THEN
    RAISE NOTICE 'seq-floor: no old DB named packiot on this server — only the production id block is applied';
  END IF;
  FOR r IN SELECT s.oid::regclass AS seq, c.relname AS tname, a.attname AS col
             FROM pg_class s JOIN pg_depend d ON d.objid = s.oid AND d.deptype IN ('a','i')
             JOIN pg_class c ON c.oid = d.refobjid JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
            WHERE s.relkind = 'S' AND s.relnamespace::regnamespace::text !~ '^(_timescaledb|timescaledb)' LOOP
    -- staging was BORN with packml_register → topic_routing (build.py TABLE_RENAMES / COLUMN_RENAMES)
    src_t := CASE r.tname WHEN 'topic_routing' THEN 'packml_register' ELSE r.tname END;
    src_c := CASE WHEN r.tname = 'topic_routing' AND r.col = 'id_topic_route' THEN 'id_packml_register' ELSE r.col END;
    old_max := NULL;
    IF have_old THEN BEGIN
      -- the old prod DB keeps every app table in `public` (the layout build.py's copy phase reads via old_public)
      SELECT m INTO old_max FROM dblink('dbname=packiot', format('SELECT max(%I)::bigint FROM public.%I', src_c, src_t)) AS t(m bigint);
    EXCEPTION WHEN others THEN old_max := NULL; END; END IF;
    IF old_max IS NULL THEN
      skipped := skipped + 1;
    ELSE
      EXECUTE format('SELECT last_value FROM %s', r.seq) INTO cur;
      IF old_max > cur THEN
        PERFORM setval(r.seq, old_max);
        raised := raised + 1;
        RAISE NOTICE 'seq-floor: % % → % (old %.% max)', r.seq, cur, old_max, src_t, src_c;
      END IF;
    END IF;
    -- ADR-0064 production id block (every sequence, whether or not the old DB had the table)
    IF r.tname NOT IN ('knex_migrations', 'knex_migrations_lock') THEN
      EXECUTE format('SELECT last_value FROM %s', r.seq) INTO cur;
      IF cur < 1000000000 THEN
        PERFORM setval(r.seq, 1000000000);
        blocked := blocked + 1;
      END IF;
    END IF;
  END LOOP;
  RAISE NOTICE 'seq-floor: raised %, unchanged/absent-in-old %, floored to the 1e9 production block %', raised, skipped, blocked;
END $f$;
