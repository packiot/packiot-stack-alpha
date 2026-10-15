-- t-ts-c3-partition-tooling — ADR-0063 Phase C3: convert a TimescaleDB hypertable into a native
-- PARTITION BY RANGE table, online, without losing rows that change during the copy (2026-10-15).
--
-- Tooling only: nothing is converted by this migration. Per table, the operator runs:
--   CALL ops.pc_prepare('silver.equipment_events', interval '1 month');  -- twin + partitions + capture
--   CALL ops.pc_copy('silver.equipment_events');                           -- one partition per transaction
--   -- window: stop the table's writers, then in ONE transaction:
--   SELECT ops.pc_swap('silver.equipment_events');                         -- replay, verify, carry over, rename
--   -- start the writers; the old hypertable stays as <name>__ts until dropped by hand.
-- and ops.partition_maintain() keeps partitions ahead of time and drops whole partitions past retention.
--
-- WHY A CHANGE-CAPTURE TRIGGER: rows are UPDATEd after insert (event closes, justifications), so a
-- copy by time range alone would miss changes to rows already copied. A row trigger on the source
-- records the key of every row inserted/updated/deleted after pc_prepare; pc_swap re-copies exactly
-- those keys under ACCESS EXCLUSIVE, so the twin equals the source when it takes over.
-- WHY RE-ISSUE VIEWS: a view binds to its tables by OID, so after the rename it would still read the
-- old table; pc_swap captures each dependent view's definition before the rename and re-creates it.
-- Carried over: owner, grants, RLS (+ FORCE) and policies, non-TimescaleDB triggers, the table comment
-- (LIKE copies column comments), identity (continued from max), sequences owned by the old table.
\set ON_ERROR_STOP 1
BEGIN;

CREATE TABLE IF NOT EXISTS ops.pc_state (
  rel          text PRIMARY KEY,          -- the original, schema-qualified (stays the name after the swap)
  twin         text NOT NULL,             -- <rel>__p while preparing
  capture      text NOT NULL,             -- <rel>__cc
  time_col     text NOT NULL,
  key_cols     text[] NOT NULL,           -- a unique key that contains time_col
  step         interval NOT NULL,         -- partition width
  copied       timestamptz[] NOT NULL DEFAULT '{}',  -- lower bounds of partitions already copied
  prepared_at  timestamptz NOT NULL DEFAULT now(),
  swapped_at   timestamptz,
  old_name     text                       -- <rel>__ts after the swap
);
COMMENT ON TABLE ops.pc_state IS 'ADR-0063 C3: one row per hypertable converted (or being converted) to native partitions by ops.pc_*';

-- partition bounds for a step (1 day / 1 week / 1 month), aligned like date_trunc
CREATE OR REPLACE FUNCTION ops.pc_floor(p_ts timestamptz, p_step interval) RETURNS timestamptz
LANGUAGE sql IMMUTABLE AS $f$
  SELECT CASE WHEN p_step >= interval '1 month' THEN date_trunc('month', p_ts AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
              WHEN p_step >= interval '7 days'  THEN date_trunc('week',  p_ts AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
              ELSE date_trunc('day', p_ts AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' END
$f$;

-- create the partitions of p_parent covering [p_from, p_to) (idempotent); returns how many were created
CREATE OR REPLACE FUNCTION ops.pc_add_partitions(p_parent regclass, p_step interval, p_from timestamptz, p_to timestamptz)
RETURNS integer LANGUAGE plpgsql AS $f$
DECLARE lo timestamptz := ops.pc_floor(p_from, p_step); hi timestamptz; nm text; n int := 0;
        sch text := (SELECT nspname FROM pg_namespace WHERE oid = (SELECT relnamespace FROM pg_class WHERE oid = p_parent));
        base text := (SELECT replace(relname, '__p', '') FROM pg_class WHERE oid = p_parent);
BEGIN
  WHILE lo < p_to LOOP
    hi := lo + p_step;
    nm := base || '_p' || to_char(lo AT TIME ZONE 'UTC', 'YYYYMMDD');
    IF to_regclass(format('%I.%I', sch, nm)) IS NULL THEN
      EXECUTE format('CREATE TABLE %I.%I PARTITION OF %s FOR VALUES FROM (%L) TO (%L)', sch, nm, p_parent, lo, hi);
      n := n + 1;
    END IF;
    lo := hi;
  END LOOP;
  RETURN n;
END $f$;

CREATE OR REPLACE PROCEDURE ops.pc_prepare(p_rel regclass, p_step interval, p_ahead interval DEFAULT interval '60 days')
LANGUAGE plpgsql AS $p$
DECLARE
  sch text; nm text; twin text; cc text; tcol text; keys text[]; mn timestamptz; n int;
BEGIN
  SELECT n.nspname, c.relname INTO sch, nm FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = p_rel;
  IF EXISTS (SELECT 1 FROM ops.pc_state WHERE rel = format('%I.%I', sch, nm)) THEN
    RAISE EXCEPTION '% is already prepared (ops.pc_state)', p_rel;
  END IF;
  SELECT column_name INTO tcol FROM timescaledb_information.dimensions
   WHERE hypertable_schema = sch AND hypertable_name = nm AND dimension_number = 1;
  IF tcol IS NULL THEN RAISE EXCEPTION '% is not a hypertable', p_rel; END IF;
  -- a unique key that contains the time column (native partitioning requires it in every unique index)
  SELECT array_agg(a.attname ORDER BY k.ord) INTO keys
    FROM (SELECT i.indexrelid, i.indkey FROM pg_index i WHERE i.indrelid = p_rel AND i.indisunique
           AND EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = p_rel AND a.attname = tcol AND a.attnum = ANY (i.indkey))
           ORDER BY i.indisprimary DESC, i.indexrelid LIMIT 1) ix,
         unnest(ix.indkey) WITH ORDINALITY k(attnum, ord) JOIN pg_attribute a ON a.attrelid = p_rel AND a.attnum = k.attnum;
  IF keys IS NULL THEN RAISE EXCEPTION '% has no unique index containing %', p_rel, tcol; END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute a WHERE a.attrelid = p_rel AND a.attname = ANY (keys) AND NOT a.attnotnull) THEN
    RAISE EXCEPTION '% key (%) has a nullable column: the swap replays by = and would miss NULL keys', p_rel, array_to_string(keys, ', ');
  END IF;
  twin := format('%I.%I', sch, nm || '__p');
  cc   := format('%I.%I', sch, nm || '__cc');

  EXECUTE format('CREATE TABLE %s (LIKE %s INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING GENERATED INCLUDING IDENTITY '
                 'INCLUDING STORAGE INCLUDING COMMENTS INCLUDING INDEXES) PARTITION BY RANGE (%I)', twin, p_rel, tcol);
  EXECUTE format('SELECT min(%I) FROM %s', tcol, p_rel) INTO mn;
  n := ops.pc_add_partitions(twin::regclass, p_step, coalesce(mn, now()), now() + p_ahead);
  -- a DEFAULT partition catches rows outside every range (clock-skewed PLC, an old backfill): without it
  -- such an insert fails, and the writer's whole transaction (silver included) with it (2026-10-15)
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I.%I PARTITION OF %s DEFAULT', sch, nm || '_pdefault', twin);

  -- change capture: the key of every row touched from now on
  EXECUTE format('CREATE TABLE %s AS SELECT %s FROM %s WITH NO DATA', cc,
                 (SELECT string_agg(quote_ident(k), ', ') FROM unnest(keys) k), p_rel);
  -- SECURITY DEFINER (2026-10-15 incident): the trigger runs in the WRITER's transaction. As the
  -- writing role, least-privilege writers (stream_engine) had no INSERT on the new capture table, so
  -- every ingest transaction failed for ~10 minutes. As the owner, any writer can be captured.
  EXECUTE format($t$CREATE OR REPLACE FUNCTION %s() RETURNS trigger LANGUAGE plpgsql
    SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $b$
    BEGIN
      IF TG_OP IN ('UPDATE', 'DELETE') THEN INSERT INTO %s VALUES (%s); END IF;
      IF TG_OP IN ('INSERT', 'UPDATE') THEN INSERT INTO %s VALUES (%s); END IF;
      RETURN NULL;
    END $b$$t$,
    format('%I.%I', sch, 'pc_capture_' || nm), cc,
    (SELECT string_agg('OLD.' || quote_ident(k), ', ') FROM unnest(keys) k), cc,
    (SELECT string_agg('NEW.' || quote_ident(k), ', ') FROM unnest(keys) k));
  EXECUTE format('CREATE TRIGGER pc_capture AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION %I.%I()',
                 p_rel, sch, 'pc_capture_' || nm);

  INSERT INTO ops.pc_state (rel, twin, capture, time_col, key_cols, step)
  VALUES (format('%I.%I', sch, nm), twin, cc, tcol, keys, p_step);
  RAISE NOTICE '%: twin % with % partitions, capture on (%), partition key %', p_rel, twin, n, array_to_string(keys, ', '), tcol;
END $p$;

-- Copy partition by partition, one transaction each (resumable: copied bounds are recorded).
-- No SET clause on purpose: a procedure with one cannot COMMIT.
CREATE OR REPLACE PROCEDURE ops.pc_copy(p_rel regclass)
LANGUAGE plpgsql AS $p$
DECLARE s ops.pc_state; part record; n bigint; total bigint := 0;
BEGIN
  SELECT * INTO s FROM ops.pc_state WHERE rel = p_rel::text OR rel = (SELECT format('%I.%I', nspname, relname) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = p_rel);
  IF s.rel IS NULL OR s.swapped_at IS NOT NULL THEN RAISE EXCEPTION '% is not prepared (or already swapped)', p_rel; END IF;
  FOR part IN
    SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \(''([^'']+)''\)'))[1]::timestamptz AS lo,
           (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz AS hi
      FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid WHERE i.inhparent = s.twin::regclass ORDER BY 1
  LOOP
    CONTINUE WHEN part.lo IS NULL OR part.lo = ANY (s.copied);   -- NULL = the DEFAULT partition
    EXECUTE format('INSERT INTO %s OVERRIDING SYSTEM VALUE SELECT * FROM %s WHERE %I >= $1 AND %I < $2 ON CONFLICT DO NOTHING',
                   s.twin, p_rel, s.time_col, s.time_col) USING part.lo, part.hi;
    GET DIAGNOSTICS n = ROW_COUNT; total := total + n;
    UPDATE ops.pc_state SET copied = copied || part.lo WHERE rel = s.rel;
    s.copied := s.copied || part.lo;
    COMMIT;
  END LOOP;
  RAISE NOTICE '%: % rows copied', p_rel, total;
END $p$;

-- The swap: run in ONE transaction, writers stopped. Returns a short report.
CREATE OR REPLACE FUNCTION ops.pc_swap(p_rel regclass) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE
  s ops.pc_state; sch text; nm text; old text; keyl text; joincond text;
  n_src bigint; n_twin bigint; replayed bigint; r record; views text[] := '{}'; vdefs text[] := '{}'; vopts text[] := '{}';
  i int; tw regclass; idcol text; mx bigint; rep text := '';
BEGIN
  SELECT n.nspname, c.relname INTO sch, nm FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = p_rel;
  SELECT * INTO s FROM ops.pc_state WHERE rel = format('%I.%I', sch, nm);
  IF s.rel IS NULL OR s.swapped_at IS NOT NULL THEN RAISE EXCEPTION '% is not prepared (or already swapped)', p_rel; END IF;
  tw := s.twin::regclass;
  EXECUTE format('LOCK TABLE %s IN ACCESS EXCLUSIVE MODE', p_rel);

  -- 1. not-yet-copied partitions, then replay every captured key
  FOR r IN SELECT (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'FROM \(''([^'']+)''\)'))[1]::timestamptz AS lo,
                  (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz AS hi
             FROM pg_inherits ih JOIN pg_class c ON c.oid = ih.inhrelid WHERE ih.inhparent = tw LOOP
    CONTINUE WHEN r.lo IS NULL OR r.lo = ANY (s.copied);   -- NULL = the DEFAULT partition
    EXECUTE format('INSERT INTO %s OVERRIDING SYSTEM VALUE SELECT * FROM %s WHERE %I >= $1 AND %I < $2 ON CONFLICT DO NOTHING',
                   tw, p_rel, s.time_col, s.time_col) USING r.lo, r.hi;
  END LOOP;
  keyl := (SELECT string_agg(quote_ident(k), ', ') FROM unnest(s.key_cols) k);
  -- plain = (2026-10-15): IS NOT DISTINCT FROM cannot use an index or a hash join, so the replay became a
  -- nested loop (667 keys x 461k rows held the canary's ACCESS EXCLUSIVE lock ~5 minutes; on bronze,
  -- 26k keys x 26M rows, it would have been hours). The keys come from a unique index of NOT NULL columns.
  joincond := (SELECT string_agg(format('t.%1$I = c.%1$I', k), ' AND ') FROM unnest(s.key_cols) k);
  EXECUTE format('DELETE FROM %s t USING (SELECT DISTINCT %s FROM %s) c WHERE %s', tw, keyl, s.capture, joincond);
  EXECUTE format('INSERT INTO %s OVERRIDING SYSTEM VALUE SELECT t.* FROM %s t JOIN (SELECT DISTINCT %s FROM %s) c ON %s',
                 tw, p_rel, keyl, s.capture, joincond);
  GET DIAGNOSTICS replayed = ROW_COUNT;

  -- 2. verify: same rows (count) — anything else aborts the whole swap
  EXECUTE format('SELECT count(*) FROM %s', p_rel) INTO n_src;
  EXECUTE format('SELECT count(*) FROM %s', tw) INTO n_twin;
  IF n_src <> n_twin THEN RAISE EXCEPTION 'pc_swap %: source % rows, twin % rows — aborted', p_rel, n_src, n_twin; END IF;

  -- 3. dependent views: capture definitions BEFORE the rename (they bind by OID)
  FOR r IN SELECT DISTINCT dc.oid AS v FROM pg_depend d JOIN pg_rewrite rw ON rw.oid = d.objid JOIN pg_class dc ON dc.oid = rw.ev_class
            WHERE d.classid = 'pg_rewrite'::regclass AND d.refobjid = p_rel AND dc.oid <> p_rel AND dc.relkind = 'v'
              AND dc.relnamespace::regnamespace::text NOT LIKE '\_timescaledb%' LOOP
    views := views || r.v::regclass::text;
    vdefs := vdefs || pg_get_viewdef(r.v, true);
    vopts := vopts || coalesce((SELECT ' WITH (' || array_to_string(reloptions, ', ') || ')' FROM pg_class WHERE oid = r.v AND reloptions IS NOT NULL), '');
  END LOOP;

  -- 4. carry over: owner, grants, RLS + policies, triggers, table comment, identity, owned sequences
  EXECUTE format('ALTER TABLE %s OWNER TO %I', tw, (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = p_rel));
  FOR r IN SELECT a.privilege_type, CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(a.grantee)) END AS who
             FROM pg_class c, aclexplode(c.relacl) a WHERE c.oid = p_rel AND a.grantee <> c.relowner LOOP
    EXECUTE format('GRANT %s ON %s TO %s', r.privilege_type, tw, r.who);
  END LOOP;
  IF (SELECT relrowsecurity FROM pg_class WHERE oid = p_rel) THEN EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', tw); END IF;
  IF (SELECT relforcerowsecurity FROM pg_class WHERE oid = p_rel) THEN EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', tw); END IF;
  FOR r IN SELECT polname, polpermissive, polcmd, polroles, pg_get_expr(polqual, polrelid) AS q, pg_get_expr(polwithcheck, polrelid) AS w
             FROM pg_policy WHERE polrelid = p_rel LOOP
    EXECUTE format('CREATE POLICY %I ON %s AS %s FOR %s TO %s%s%s', r.polname, tw,
                   CASE WHEN r.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
                   CASE r.polcmd WHEN 'r' THEN 'SELECT' WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' ELSE 'ALL' END,
                   (SELECT string_agg(CASE WHEN x = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(x)) END, ', ') FROM unnest(r.polroles) x),
                   coalesce(' USING (' || r.q || ')', ''), coalesce(' WITH CHECK (' || r.w || ')', ''));
  END LOOP;
  FOR r IN SELECT tgname, pg_get_triggerdef(oid) AS def FROM pg_trigger
            WHERE tgrelid = p_rel AND NOT tgisinternal AND tgname <> 'pc_capture' AND tgname NOT LIKE 'ts\_%' LOOP
    -- pg_get_triggerdef prints the table schema-qualified; regclass::text drops the schema when it is on
    -- the search_path (staging: silver, bronze) — so match the qualified name explicitly (2026-10-15).
    IF position(' ON ' || format('%I.%I', sch, nm) || ' ' in r.def) = 0 THEN
      RAISE EXCEPTION 'pc_swap %: trigger % definition does not name the table as expected: %', s.rel, r.tgname, r.def;
    END IF;
    EXECUTE replace(r.def, ' ON ' || format('%I.%I', sch, nm) || ' ', ' ON ' || s.twin || ' ');
  END LOOP;
  EXECUTE format('COMMENT ON TABLE %s IS %L', tw, obj_description(p_rel, 'pg_class'));
  FOR r IN SELECT a.attname FROM pg_attribute a WHERE a.attrelid = p_rel AND a.attidentity <> '' AND NOT a.attisdropped LOOP
    EXECUTE format('SELECT max(%I) FROM %s', r.attname, tw) INTO mx;
    IF mx IS NOT NULL THEN
      PERFORM setval(pg_get_serial_sequence(tw::text, r.attname), mx);
      rep := rep || format(' identity %s continues after %s;', r.attname, mx);
    END IF;
  END LOOP;
  FOR r IN SELECT d.objid::regclass AS seq, a.attname FROM pg_depend d JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
            WHERE d.refobjid = p_rel AND d.classid = 'pg_class'::regclass AND d.deptype = 'a'
              AND (SELECT relkind FROM pg_class WHERE oid = d.objid) = 'S' LOOP
    EXECUTE format('ALTER SEQUENCE %s OWNED BY %s.%I', r.seq, tw, r.attname);
    rep := rep || format(' sequence %s now owned by the new table;', r.seq);
  END LOOP;

  -- 5. rename: original → <name>__ts (kept for rollback), twin → original name
  EXECUTE format('DROP TRIGGER IF EXISTS pc_capture ON %s', p_rel);
  old := nm || '__ts';
  EXECUTE format('ALTER TABLE %s RENAME TO %I', p_rel, old);
  -- a table rename keeps its index names: move the old table's out of the way first (found by the test)
  FOR r IN SELECT c.relname FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
            WHERE x.indrelid = format('%I.%I', sch, old)::regclass LOOP
    EXECUTE format('ALTER INDEX %I.%I RENAME TO %I', sch, r.relname, left(r.relname, 59) || '__ts');
  END LOOP;
  EXECUTE format('ALTER TABLE %s RENAME TO %I', tw, nm);
  FOR r IN SELECT c.relname FROM pg_index x JOIN pg_class c ON c.oid = x.indexrelid
            WHERE x.indrelid = format('%I.%I', sch, nm)::regclass AND c.relname LIKE '%\_\_p\_%' LOOP
    EXECUTE format('ALTER INDEX %I.%I RENAME TO %I', sch, r.relname, replace(r.relname, '__p_', '_'));
  END LOOP;

  -- 6. re-issue the dependent views against the new table
  FOR i IN 1 .. coalesce(array_length(views, 1), 0) LOOP
    EXECUTE format('CREATE OR REPLACE VIEW %s%s AS %s', views[i], vopts[i], vdefs[i]);
  END LOOP;

  EXECUTE format('DROP TABLE %s', s.capture);
  EXECUTE format('DROP FUNCTION IF EXISTS %I.%I()', sch, 'pc_capture_' || nm);
  -- retention is no longer a TimescaleDB policy: partition_maintain drops whole partitions, and
  -- ops.apply_retention treats the table as plain (a time DELETE that then finds nothing to do)
  IF to_regclass('ops.retention_policy') IS NOT NULL THEN
    UPDATE ops.retention_policy SET kind = 'plain', updated_at = now() WHERE relation = s.rel AND kind = 'hypertable';
  END IF;
  UPDATE ops.pc_state SET swapped_at = now(), old_name = format('%I.%I', sch, old) WHERE rel = s.rel;
  RETURN format('%s: %s rows, %s replayed, %s views re-issued, old table %I.%I;%s',
                s.rel, n_twin, replayed, coalesce(array_length(views, 1), 0), sch, old, rep);
END $f$;

-- Keep partitions ahead and drop whole partitions past retention (ops.retention_policy.keep for the
-- relation, when set). Idempotent; meant to run daily (pg_cron, ADR-0063 §13.2).
CREATE OR REPLACE FUNCTION ops.partition_maintain(p_ahead interval DEFAULT interval '60 days')
RETURNS TABLE (rel text, created integer, dropped integer)
LANGUAGE plpgsql AS $f$
DECLARE s record; r record; keep interval;
BEGIN
  FOR s IN SELECT * FROM ops.pc_state WHERE swapped_at IS NOT NULL LOOP
    rel := s.rel; dropped := 0;
    created := ops.pc_add_partitions(s.rel::regclass, s.step, now(), now() + p_ahead);
    SELECT rp.keep INTO keep FROM ops.retention_policy rp WHERE rp.relation = s.rel;
    IF keep IS NOT NULL THEN
      FOR r IN SELECT c.oid::regclass AS part,
                      (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1]::timestamptz AS hi
                 FROM pg_inherits ih JOIN pg_class c ON c.oid = ih.inhrelid WHERE ih.inhparent = s.rel::regclass LOOP
        IF r.hi IS NOT NULL AND r.hi <= now() - keep THEN   -- never drop the DEFAULT partition
          EXECUTE format('ALTER TABLE %s DETACH PARTITION %s', s.rel, r.part);
          EXECUTE format('DROP TABLE %s', r.part);
          dropped := dropped + 1;
        END IF;
      END LOOP;
    END IF;
    RETURN NEXT;
  END LOOP;
END $f$;

REVOKE ALL ON FUNCTION ops.pc_swap(regclass), ops.partition_maintain(interval), ops.pc_add_partitions(regclass, interval, timestamptz, timestamptz) FROM PUBLIC;
REVOKE ALL ON PROCEDURE ops.pc_prepare(regclass, interval, interval), ops.pc_copy(regclass) FROM PUBLIC;
COMMIT;
