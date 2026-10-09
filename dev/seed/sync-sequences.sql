-- dev/seed/sync-sequences.sql — move every id sequence past the seed's loaded rows (contracts.md F11).
--
-- The seed restores a schema-only dump and then COPYs the rows in. A schema-only dump carries no sequence
-- positions (pg_dump's SEQUENCE SET entries are data), so every serial/identity sequence started at 1 while the
-- tables already held ids: the first INSERT that takes a default id collided (2026-10-08: edge-api's knex
-- migration failed on `knex_migrations_pkey (id)=(1) already exists`).
--
-- Baked into the seed image (/seed/sync-sequences.sql) and run by load.sh right after load.sql, so the published
-- image is correct for any consumer. dev/base.yml also mounts it as an initdb hook (60-devseed-sequences.sql), a
-- backstop for seed images built before 2026-10-09. Idempotent: it only ever moves a sequence forward to max(id)
-- of the columns that draw from it, so re-running it is a no-op (the seed build's boot test relies on that).
--
-- A sequence "feeds" a column when the column's DEFAULT calls nextval() on it (pg_attrdef → pg_depend) or the
-- column is an identity/serial column that owns it. A sequence shared by several columns goes past the max of all.
-- Descending sequences (e.g. production_orders_internal_id_order_seq) are left alone.
DO $$
DECLARE
  r record;
  hi bigint;
  m bigint;
BEGIN
  FOR r IN
    SELECT s.oid::regclass AS seq,
           array_agg(DISTINCT format('SELECT max(%I)::bigint FROM %s', a.attname, t.oid::regclass)) AS probes
      FROM pg_class s
      JOIN pg_sequence ps ON ps.seqrelid = s.oid AND ps.seqincrement > 0
      JOIN pg_depend d ON d.refobjid = s.oid AND d.refclassid = 'pg_class'::regclass
      JOIN pg_attrdef ad ON d.classid = 'pg_attrdef'::regclass AND d.objid = ad.oid
      JOIN pg_class t ON t.oid = ad.adrelid
      JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
     WHERE s.relkind = 'S'
     GROUP BY s.oid
    UNION ALL
    SELECT s.oid::regclass,
           array_agg(DISTINCT format('SELECT max(%I)::bigint FROM %s', a.attname, t.oid::regclass))
      FROM pg_class s
      JOIN pg_sequence ps ON ps.seqrelid = s.oid AND ps.seqincrement > 0
      JOIN pg_depend d ON d.objid = s.oid AND d.classid = 'pg_class'::regclass AND d.deptype IN ('a', 'i')
      JOIN pg_class t ON t.oid = d.refobjid
      JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
     WHERE s.relkind = 'S' AND d.refobjsubid > 0
     GROUP BY s.oid
  LOOP
    hi := NULL;
    FOR i IN 1 .. array_length(r.probes, 1) LOOP
      EXECUTE r.probes[i] INTO m;
      hi := greatest(hi, m);
    END LOOP;
    IF hi IS NOT NULL THEN
      PERFORM setval(r.seq, greatest(hi, (SELECT last_value FROM pg_sequences
                                            WHERE format('%I.%I', schemaname, sequencename)::regclass = r.seq), 1));
    END IF;
  END LOOP;
END $$;
