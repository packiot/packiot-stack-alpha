-- t-sandbox-reflection — make SANDBOX-CPACK (ent 2000003) an exact, RESETTABLE reflection
-- of CPACK staging (ent 3) on the ANALYTICS plane.
--
-- WHY: scripts/provision-sandbox-tenant.sh --heal re-clones config into the `packiot` DB,
-- but every frontend (operator, front4, csadmin, customize) reads/writes via edge-api /
-- read-api against `packiot_analytics`. So E2E mutations were never reset where they
-- live (2026-09-24: 14 leftover E2E-AREA-* rows, 0 downtime reasons → operator justify
-- had nothing to pick, 903 accumulated manual events, 270/559 POs, no history).
--
-- ID CONVENTION (matches the existing clone + the live fanout):
--   entity ids (site/area/equipment/shift/shift_hour/reason/client/product/family) +2,000,000;
--   equipment_events keep CPACK's id_equipment_event (the fanout already does — 2,962/2,962
--   pairs identical) — safe since #266 tenant-pins every mutating event statement;
--   PO / PO-runtime ids +500,000,000 (int4-safe: max CPACK id 101.7M; serving row types
--   still declare integer); manual-event ids come from their IDENTITY.
--
-- LAYERS (ops.sandbox_reflect):
--   config   — upsert CPACK→sandbox remapped; delete sandbox extras (E2E leftovers).
--   mutable  — what E2E mutates: equipment_events in the last p_window (restores justify /
--              split edits from their CPACK twin, removes split-created rows), ALL manual
--              events, ALL POs + runtimes; then refresh serving.downtime_events_resolved
--              for the window.
--   history  — (p_history) gold OEE grains, older events, resolved downtimes: fill-only
--              (ON CONFLICT DO NOTHING) so the sandbox's own pipeline rows are kept.
-- Idempotent. Everything is scoped HARD to p_dst; p_src is only ever READ.

CREATE SCHEMA IF NOT EXISTS ops;

-- Upsert helper: INSERT <select> ON CONFLICT (pk) DO UPDATE SET every non-pk column.
CREATE OR REPLACE FUNCTION ops.sbx_upsert(p_target regclass, p_pk text[], p_select text, p_override_identity boolean DEFAULT false)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE sets text; n bigint;
BEGIN
  SELECT string_agg(format('%1$I = EXCLUDED.%1$I', attname), ', ' ORDER BY attnum) INTO sets
    FROM pg_attribute
   WHERE attrelid = p_target AND attnum > 0 AND NOT attisdropped AND attgenerated = ''
     AND NOT (attname = ANY (p_pk));
  EXECUTE format('INSERT INTO %s %s %s ON CONFLICT (%s) DO %s',
                 p_target, CASE WHEN p_override_identity THEN 'OVERRIDING SYSTEM VALUE' ELSE '' END,
                 p_select,
                 array_to_string(ARRAY(SELECT quote_ident(c) FROM unnest(p_pk) c), ', '),
                 CASE WHEN sets IS NULL THEN 'NOTHING' ELSE 'UPDATE SET ' || sets END);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- Descriptor transform — the SAME rules as provision-sandbox-tenant.sh's pg_temp.sbx_remap:
-- id_equipment/id_unit +off; every string CPACK→SBXCPACK (topics, device keys, agent/tee
-- ids, secret refs). Tags parameterized so any future twin can reuse it.
CREATE OR REPLACE FUNCTION ops.sbx_remap_descriptor(j jsonb, off int, from_tag text DEFAULT 'CPACK', to_tag text DEFAULT 'SBXCPACK')
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $f$
DECLARE result jsonb; k text; v jsonb; elem jsonb; arr jsonb;
BEGIN
  IF jsonb_typeof(j) = 'object' THEN
    result := '{}'::jsonb;
    FOR k, v IN SELECT * FROM jsonb_each(j) LOOP
      IF k IN ('id_equipment', 'id_unit') AND jsonb_typeof(v) = 'number' THEN
        result := result || jsonb_build_object(k, (v::bigint + off));
      ELSE
        result := result || jsonb_build_object(k, ops.sbx_remap_descriptor(v, off, from_tag, to_tag));
      END IF;
    END LOOP;
    RETURN result;
  ELSIF jsonb_typeof(j) = 'array' THEN
    arr := '[]'::jsonb;
    FOR elem IN SELECT * FROM jsonb_array_elements(j) LOOP
      arr := arr || jsonb_build_array(ops.sbx_remap_descriptor(elem, off, from_tag, to_tag));
    END LOOP;
    RETURN arr;
  ELSIF jsonb_typeof(j) = 'string' THEN
    RETURN to_jsonb(replace(replace(j #>> '{}', from_tag, to_tag), lower(from_tag), lower(to_tag)));
  ELSE
    RETURN j;
  END IF;
END $f$;

DROP PROCEDURE IF EXISTS ops.sandbox_reflect(int, int, int, interval, boolean);
DROP PROCEDURE IF EXISTS ops.sandbox_reflect(int, int, int, interval, boolean, text, text);
CREATE OR REPLACE PROCEDURE ops.sandbox_reflect(
    p_src int DEFAULT 3, p_dst int DEFAULT 2000003, p_off int DEFAULT 2000000,
    p_window interval DEFAULT '14 days', p_history boolean DEFAULT false,
    p_src_tag text DEFAULT 'CPACK', p_dst_tag text DEFAULT 'SBXCPACK',
    p_commit boolean DEFAULT true)
LANGUAGE plpgsql AS $$
DECLARE
  n bigint; po_off constant bigint := 500000000; m date; b timestamptz; g record;
  w_from timestamptz := now() - p_window;
  -- json override snippets (entity-id remaps); %1$s = offset, %2$s = dst enterprise
  eq_map text;
BEGIN
  IF p_dst = p_src OR p_dst < 1000000 THEN
    RAISE EXCEPTION 'sandbox_reflect: refusing dst=% (must be a sandbox id >= 1,000,000 and != src)', p_dst;
  END IF;
  SET LOCAL session_replication_role = replica;   -- FK/trigger-free bulk reflect, scoped by WHERE
  -- NOTE: statement_timeout is armed when the top-level CALL starts, so it CANNOT be raised
  -- from in here — callers must `SET statement_timeout = '20min'` BEFORE the CALL (the
  -- role default of 2 min killed the first dry run mid-way).
  --
  -- SHORT TRANSACTIONS (p_commit, default true): COMMIT after every layer / history chunk.
  -- The first live run held ONE 16-minute transaction; the stream-engine rollup (which
  -- upserts the same gold/runtime rows for ALL tenants, CPACK included) waited on its
  -- locks → rollups stalled platform-wide until it was cancelled. p_commit=false keeps a
  -- whole run inside the caller's BEGIN … ROLLBACK for dry runs.

  -- ── CONFIG ────────────────────────────────────────────────────────────────
  n := ops.sbx_upsert('core.sites', '{id_site}', format($q$
    SELECT (jsonb_populate_record(NULL::core.sites, to_jsonb(x) || jsonb_build_object(
            'id_site', x.id_site + %1$s, 'id_enterprise', %2$s))).*
      FROM core.sites x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  RAISE NOTICE 'config sites upserted %', n;

  n := ops.sbx_upsert('core.areas', '{id_area}', format($q$
    SELECT (jsonb_populate_record(NULL::core.areas, to_jsonb(x) || jsonb_build_object(
            'id_area', x.id_area + %1$s, 'id_site', x.id_site + %1$s, 'id_enterprise', %2$s))).*
      FROM core.areas x JOIN core.sites s USING (id_site) WHERE s.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  -- extras (E2E-created areas): drop their derived rows first, then the areas
  DELETE FROM silver.area_live_day d USING core.areas a JOIN core.sites s USING (id_site)
   WHERE d.id_area = a.id_area AND s.id_enterprise = p_dst
     AND a.id_area - p_off NOT IN (SELECT a2.id_area FROM core.areas a2 JOIN core.sites s2 USING (id_site) WHERE s2.id_enterprise = p_src);
  DELETE FROM silver.area_live_shift d USING core.areas a JOIN core.sites s USING (id_site)
   WHERE d.id_area = a.id_area AND s.id_enterprise = p_dst
     AND a.id_area - p_off NOT IN (SELECT a2.id_area FROM core.areas a2 JOIN core.sites s2 USING (id_site) WHERE s2.id_enterprise = p_src);
  DELETE FROM gold.area_oee_shift d USING core.areas a JOIN core.sites s USING (id_site)
   WHERE d.id_area = a.id_area AND s.id_enterprise = p_dst
     AND a.id_area - p_off NOT IN (SELECT a2.id_area FROM core.areas a2 JOIN core.sites s2 USING (id_site) WHERE s2.id_enterprise = p_src);
  DELETE FROM gold.area_oee_daily d USING core.areas a JOIN core.sites s USING (id_site)
   WHERE d.id_area = a.id_area AND s.id_enterprise = p_dst
     AND a.id_area - p_off NOT IN (SELECT a2.id_area FROM core.areas a2 JOIN core.sites s2 USING (id_site) WHERE s2.id_enterprise = p_src);
  DELETE FROM core.areas a USING core.sites s
   WHERE a.id_site = s.id_site AND s.id_enterprise = p_dst
     AND a.id_area - p_off NOT IN (SELECT a2.id_area FROM core.areas a2 JOIN core.sites s2 USING (id_site) WHERE s2.id_enterprise = p_src);
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'config areas: extras deleted %', n;

  eq_map := format($m$'id_equipment', x.id_equipment + %1$s, 'id_area', x.id_area + %1$s, 'id_site', x.id_site + %1$s,
                     'id_enterprise', %2$s, 'id_parentequipment', x.id_parentequipment + %1$s,
                     'lead_machine', x.lead_machine + %1$s$m$, p_off, p_dst);
  n := ops.sbx_upsert('core.equipments', '{id_equipment}', format($q$
    SELECT (jsonb_populate_record(NULL::core.equipments, to_jsonb(x) || jsonb_build_object(%1$s))).*
      FROM core.equipments x WHERE x.id_enterprise = %2$s $q$, eq_map, p_src));
  RAISE NOTICE 'config equipments upserted %', n;

  n := ops.sbx_upsert('core.shifts', '{id_shift}', format($q$
    SELECT (jsonb_populate_record(NULL::core.shifts, to_jsonb(x) || jsonb_build_object(
            'id_shift', x.id_shift + %1$s, 'id_area', x.id_area + %1$s, 'id_site', x.id_site + %1$s,
            'id_equipment', x.id_equipment + %1$s, 'id_enterprise', %2$s))).*
      FROM core.shifts x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  n := ops.sbx_upsert('core.shift_hours', '{id_shift_hour}', format($q$
    SELECT (jsonb_populate_record(NULL::core.shift_hours, to_jsonb(x) || jsonb_build_object(
            'id_shift_hour', x.id_shift_hour + %1$s, 'id_shift', x.id_shift + %1$s, 'id_area', x.id_area + %1$s,
            'id_site', x.id_site + %1$s, 'id_equipment', x.id_equipment + %1$s, 'id_enterprise', %2$s))).*
      FROM core.shift_hours x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  DELETE FROM core.shift_hours WHERE id_enterprise = p_dst
     AND id_shift_hour - p_off NOT IN (SELECT id_shift_hour FROM core.shift_hours WHERE id_enterprise = p_src);
  DELETE FROM core.shifts WHERE id_enterprise = p_dst
     AND id_shift - p_off NOT IN (SELECT id_shift FROM core.shifts WHERE id_enterprise = p_src);

  n := ops.sbx_upsert('config.production_targets', '{id_equipment,id_site}', format($q$
    SELECT (jsonb_populate_record(NULL::config.production_targets, to_jsonb(x) || jsonb_build_object(
            'id_equipment', x.id_equipment + %1$s, 'id_site', x.id_site + %1$s, 'id_area', x.id_area + %1$s,
            'id_enterprise', %2$s))).*
      FROM config.production_targets x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  RAISE NOTICE 'config production_targets upserted %', n;

  -- downtime reason taxonomy (operator justify/split pick from it; csadmin edits it)
  DELETE FROM core.equipment_downtime_reason r USING core.equipments e
   WHERE r.id_equipment = e.id_equipment AND e.id_enterprise = p_dst;
  DELETE FROM core.downtime_reason WHERE id_enterprise = p_dst;
  n := ops.sbx_upsert('core.downtime_reason', '{id}', format($q$
    SELECT (jsonb_populate_record(NULL::core.downtime_reason, to_jsonb(x) || jsonb_build_object(
            'id', x.id + %1$s, 'parent_id', x.parent_id + %1$s, 'id_enterprise', %2$s))).*
      FROM core.downtime_reason x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src), true);
  RAISE NOTICE 'config downtime_reason reflected %', n;
  n := ops.sbx_upsert('core.equipment_downtime_reason', '{id_equipment,id_reason}', format($q$
    SELECT (jsonb_populate_record(NULL::core.equipment_downtime_reason, to_jsonb(x) || jsonb_build_object(
            'id_equipment', x.id_equipment + %1$s, 'id_reason', x.id_reason + %1$s))).*
      FROM core.equipment_downtime_reason x JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise = %2$s $q$, p_off, p_src));
  RAISE NOTICE 'config equipment_downtime_reason reflected %', n;

  -- dimensions POs reference (names shown in Orders)
  n := ops.sbx_upsert('core.clients', '{id_client}', format($q$
    SELECT (jsonb_populate_record(NULL::core.clients, to_jsonb(x) || jsonb_build_object(
            'id_client', x.id_client + %1$s, 'id_enterprise', %2$s))).*
      FROM core.clients x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  n := ops.sbx_upsert('core.product_families', '{id_product_family}', format($q$
    SELECT (jsonb_populate_record(NULL::core.product_families, to_jsonb(x) || jsonb_build_object(
            'id_product_family', x.id_product_family + %1$s, 'id_enterprise', %2$s))).*
      FROM core.product_families x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  n := ops.sbx_upsert('core.products', '{id_product}', format($q$
    SELECT (jsonb_populate_record(NULL::core.products, to_jsonb(x) || jsonb_build_object(
            'id_product', x.id_product + %1$s, 'id_product_family', x.id_product_family + %1$s, 'id_enterprise', %2$s))).*
      FROM core.products x WHERE x.id_enterprise = %3$s $q$, p_off, p_dst, p_src));
  RAISE NOTICE 'config clients/families/products reflected (products %)', n;

  -- client descriptor (tag map / derive rules / oee_profile): the remapped CPACK
  -- descriptor, EXCEPT sandbox-owned keys kept as-is — `capabilities` carries the
  -- sandbox-only simulated-ERP integration demo (not a CPACK property). Resets
  -- customize-authored derive rules (E2E) and adds CPACK's oee_profile (parity).
  UPDATE core.client_descriptors d
     SET descriptor = jsonb_set(jsonb_set(ops.sbx_remap_descriptor(c.descriptor, p_off, p_src_tag, p_dst_tag),
                                          '{enterprise_id}', to_jsonb(p_dst)), '{tenant}', to_jsonb(p_dst_tag))
                      || CASE WHEN d.descriptor ? 'capabilities'
                              THEN jsonb_build_object('capabilities', d.descriptor->'capabilities') ELSE '{}'::jsonb END,
         status = 'generated', updated_at = now(), updated_by = 'sandbox-reflect:ent' || p_src
    FROM core.client_descriptors c
   WHERE d.id_enterprise = p_dst AND c.id_enterprise = p_src;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'config client_descriptor reflected % (sandbox capabilities preserved)', n;
  IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; END IF;

  -- ── MUTABLE DATA ──────────────────────────────────────────────────────────
  -- equipment_events in the window: remove sandbox rows with no CPACK twin (split-created),
  -- then upsert every CPACK row remapped (restores justify/split edits, fills fanout gaps).
  DROP TABLE IF EXISTS _sbx_ev;
  CREATE TEMP TABLE _sbx_ev AS
  SELECT (jsonb_populate_record(NULL::silver.equipment_events, to_jsonb(x) || jsonb_build_object(
          'id_equipment', x.id_equipment + p_off, 'id_enterprise', p_dst))).*
    FROM silver.equipment_events x WHERE x.id_enterprise = p_src AND x.ts_event >= w_from;
  DELETE FROM silver.equipment_events s
   WHERE s.id_enterprise = p_dst AND s.ts_event >= w_from
     AND NOT EXISTS (SELECT 1 FROM silver.equipment_events c
                      WHERE c.id_equipment = s.id_equipment - p_off AND c.ts_event = s.ts_event AND c.id_enterprise = p_src);
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'events: % sandbox-only rows removed (window %)', n, p_window;
  n := ops.sbx_upsert('silver.equipment_events', '{id_equipment,ts_event}', 'SELECT * FROM _sbx_ev');
  DROP TABLE _sbx_ev;
  RAISE NOTICE 'events: % rows reflected', n;
  IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; END IF;

  -- manual events (operator justify / split / manual downtime): ALL, reflected from CPACK
  DELETE FROM silver.equipment_events_man m USING core.equipments e
   WHERE m.id_equipment = e.id_equipment AND e.id_enterprise = p_dst;
  INSERT INTO silver.equipment_events_man
  SELECT (jsonb_populate_record(NULL::silver.equipment_events_man, to_jsonb(x) || jsonb_build_object(
          'id_equipment', x.id_equipment + p_off, 'id_enterprise', p_dst,
          'id_equipment_event', nextval(pg_get_serial_sequence('silver.equipment_events_man', 'id_equipment_event'))))).*
    FROM silver.equipment_events_man x JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise = p_src;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'manual events reflected %', n;
  IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; END IF;

  -- POs + runtimes (+ box counters): ALL, reflected. The replicator keys on
  -- (id_enterprise,id_order), so the new ids stay compatible with its future updates.
  -- STAGE FIRST, SWAP FAST: the jsonb transform of ~19k rows runs into temp tables
  -- (reads CPACK only, locks nothing on the sandbox); the swap below is a plain
  -- DELETE + INSERT…SELECT, so the po-runtime loop never waits more than seconds
  -- (transforming inside the swap held sandbox row locks ~minutes → watchdog cancel).
  DROP TABLE IF EXISTS _sbx_po; DROP TABLE IF EXISTS _sbx_rt;
  CREATE TEMP TABLE _sbx_po AS
  SELECT (jsonb_populate_record(NULL::core.production_orders, to_jsonb(x) || jsonb_build_object(
          'id_production_order', x.id_production_order + po_off, 'id_enterprise', p_dst,
          'id_site', x.id_site + p_off, 'id_area', x.id_area + p_off, 'id_equipment', x.id_equipment + p_off,
          'id_client', x.id_client + p_off, 'id_product', x.id_product + p_off,
          'id_user_operator', NULL, 'id_equipment_executed', x.id_equipment_executed + p_off, 'id_label', NULL))).*
    FROM core.production_orders x WHERE x.id_enterprise = p_src;
  CREATE TEMP TABLE _sbx_rt AS
  SELECT (jsonb_populate_record(NULL::gold.production_orders_runtime, to_jsonb(x) || jsonb_build_object(
          'id_production_order', x.id_production_order + po_off, 'id_equipment', x.id_equipment + p_off,
          'id_production_order_runtime', x.id_production_order_runtime + po_off,
          'id_production_orders_runtime', x.id_production_orders_runtime + po_off))).*
    FROM gold.production_orders_runtime x JOIN core.production_orders p USING (id_production_order)
   WHERE p.id_enterprise = p_src;
  -- fast swap
  DELETE FROM gold.po_box_counter b USING core.production_orders p
   WHERE b.id_production_order = p.id_production_order AND p.id_enterprise = p_dst;
  DELETE FROM bronze.box_scans b USING core.production_orders p
   WHERE b.id_production_order = p.id_production_order AND p.id_enterprise = p_dst;
  DELETE FROM gold.production_orders_runtime r USING core.equipments e
   WHERE r.id_equipment = e.id_equipment AND e.id_enterprise = p_dst;
  DELETE FROM core.production_orders WHERE id_enterprise = p_dst;
  INSERT INTO core.production_orders OVERRIDING SYSTEM VALUE SELECT * FROM _sbx_po;
  GET DIAGNOSTICS n = ROW_COUNT;
  RAISE NOTICE 'POs reflected %', n;
  INSERT INTO gold.production_orders_runtime OVERRIDING SYSTEM VALUE SELECT * FROM _sbx_rt ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  DROP TABLE _sbx_po; DROP TABLE _sbx_rt;
  RAISE NOTICE 'PO runtimes reflected %', n;
  IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; END IF;

  -- ── HISTORY (fill-only, strictly BELOW the range the sandbox pipeline owns) ─────
  -- Every fill is bounded by the sandbox's OWN earliest row for that relation (the
  -- pipeline writes from there forward) — the first run filled recent dates too and its
  -- inserts collided with the live rollup's upserts (lock waits). Chunked per month /
  -- per grain with a COMMIT each, so no lock outlives one chunk.
  IF p_history THEN
    -- Memory: every chunk below is ONE month, committed, with a small work_mem — the
    -- first run inserted each gold grain in one statement (up to 634k rows through jsonb)
    -- next to a heavy ad-hoc scan and a backend hit 7 GB → kernel OOM-kill → crash
    -- recovery of the whole cluster (2026-09-24 11:23).
    SET LOCAL work_mem = '32MB';
    -- events older than the reflected window, month by month: REPLACE, not fill — drop
    -- sandbox-only rows (the twin's early never-closed junk: 14,906 open events Jun–Aug
    -- 2026) then fill from CPACK.
    FOR m IN SELECT generate_series(date_trunc('month', (SELECT min(ts_event) FROM silver.equipment_events WHERE id_enterprise = p_src)),
                                    date_trunc('month', w_from), interval '1 month')::date LOOP
      DELETE FROM silver.equipment_events s
       WHERE s.id_enterprise = p_dst AND s.ts_event >= m AND s.ts_event < least(m + interval '1 month', w_from)
         AND NOT EXISTS (SELECT 1 FROM silver.equipment_events c
                          WHERE c.id_enterprise = p_src AND c.id_equipment = s.id_equipment - p_off AND c.ts_event = s.ts_event);
      INSERT INTO silver.equipment_events
      SELECT (jsonb_populate_record(NULL::silver.equipment_events, to_jsonb(x) || jsonb_build_object(
              'id_equipment', x.id_equipment + p_off, 'id_enterprise', p_dst))).*
        FROM silver.equipment_events x
       WHERE x.id_enterprise = p_src AND x.ts_event >= m AND x.ts_event < least(m + interval '1 month', w_from)
      ON CONFLICT DO NOTHING;
      GET DIAGNOSTICS n = ROW_COUNT;
      IF n > 0 THEN RAISE NOTICE 'history events % filled %', to_char(m, 'YYYY-MM'), n; END IF;
      IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; SET LOCAL work_mem = '32MB'; END IF;
    END LOOP;

    -- gold grains keyed by equipment: bounded below the sandbox's earliest row per grain,
    -- one MONTH per statement + commit
    FOR g IN SELECT * FROM (VALUES ('gold.equipment_oee_shift', true), ('gold.equipment_oee_hourly', false),
                                   ('gold.equipment_oee_daily', false), ('gold.equipment_oee_weekly', false),
                                   ('gold.equipment_oee_monthly', false)) v(tbl, is_shift) LOOP
      EXECUTE format('SELECT min(o.ts_value)::timestamptz FROM %s o JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise = $1', g.tbl)
        INTO b USING p_dst;
      FOR m IN EXECUTE format('SELECT generate_series(date_trunc(''month'', min(o.ts_value)::timestamptz), date_trunc(''month'', coalesce($2, now())), interval ''1 month'')::date
                                 FROM %s o JOIN core.equipments e USING (id_equipment) WHERE e.id_enterprise = $1', g.tbl) USING p_src, b LOOP
        EXECUTE format($q$
          INSERT INTO %1$s SELECT (jsonb_populate_record(NULL::%1$s, to_jsonb(x) || jsonb_build_object(
                 'id_equipment', x.id_equipment + $1 %2$s))).*
            FROM %1$s x JOIN core.equipments e USING (id_equipment)
           WHERE e.id_enterprise = $2 AND x.ts_value >= $4 AND x.ts_value < $4 + interval '1 month'
             AND ($3::timestamptz IS NULL OR x.ts_value < $3)
          ON CONFLICT DO NOTHING $q$, g.tbl,
          CASE WHEN g.is_shift THEN $x$, 'id_shift', x.id_shift + $1, 'id_shift_hour', x.id_shift_hour + $1,
               'id_runtime_shift', nextval(pg_get_serial_sequence('gold.equipment_oee_shift', 'id_runtime_shift'))$x$ ELSE '' END)
          USING p_off, p_src, b, m;
        IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; SET LOCAL work_mem = '32MB'; END IF;
      END LOOP;
      RAISE NOTICE 'history % filled (below %)', g.tbl, coalesce(b::text, 'no sandbox rows');
    END LOOP;

    -- area / site grains
    SELECT min(o.ts_value) INTO b FROM gold.area_oee_shift o JOIN core.areas a USING (id_area) JOIN core.sites s USING (id_site) WHERE s.id_enterprise = p_dst;
    INSERT INTO gold.area_oee_shift SELECT (jsonb_populate_record(NULL::gold.area_oee_shift, to_jsonb(x) || jsonb_build_object(
            'id_area', x.id_area + p_off, 'id_shift', x.id_shift + p_off, 'id_shift_hour', x.id_shift_hour + p_off))).*
      FROM gold.area_oee_shift x JOIN core.areas a USING (id_area) JOIN core.sites s USING (id_site)
     WHERE s.id_enterprise = p_src AND (b IS NULL OR x.ts_value < b) ON CONFLICT DO NOTHING;
    SELECT min(o.ts_value)::timestamptz INTO b FROM gold.area_oee_daily o JOIN core.areas a USING (id_area) JOIN core.sites s USING (id_site) WHERE s.id_enterprise = p_dst;
    INSERT INTO gold.area_oee_daily SELECT (jsonb_populate_record(NULL::gold.area_oee_daily, to_jsonb(x) || jsonb_build_object(
            'id_area', x.id_area + p_off))).*
      FROM gold.area_oee_daily x JOIN core.areas a USING (id_area) JOIN core.sites s USING (id_site)
     WHERE s.id_enterprise = p_src AND (b IS NULL OR x.ts_value < b) ON CONFLICT DO NOTHING;
    SELECT min(o.ts_value) INTO b FROM gold.site_oee_shift o JOIN core.sites s USING (id_site) WHERE s.id_enterprise = p_dst;
    INSERT INTO gold.site_oee_shift SELECT (jsonb_populate_record(NULL::gold.site_oee_shift, to_jsonb(x) || jsonb_build_object(
            'id_site', x.id_site + p_off, 'id_shift', x.id_shift + p_off, 'id_shift_hour', x.id_shift_hour + p_off))).*
      FROM gold.site_oee_shift x JOIN core.sites s USING (id_site)
     WHERE s.id_enterprise = p_src AND (b IS NULL OR x.ts_value < b) ON CONFLICT DO NOTHING;
    RAISE NOTICE 'history area/site grains filled';
    IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; END IF;

    -- resolved downtimes older than the window: copy CPACK's materialized rows, month by month
    FOR m IN SELECT generate_series(date_trunc('month', (SELECT min(ts_event) FROM serving.downtime_events_resolved WHERE id_enterprise = p_src)),
                                    date_trunc('month', w_from), interval '1 month')::date LOOP
      INSERT INTO serving.downtime_events_resolved
      SELECT (jsonb_populate_record(NULL::serving.downtime_events_resolved, to_jsonb(x) || jsonb_build_object(
              'id_equipment', x.id_equipment + p_off, 'id_sector', x.id_sector + p_off, 'id_line', x.id_line + p_off,
              'id_area', x.id_area + p_off, 'id_site', x.id_site + p_off, 'id_parentequipment', x.id_parentequipment + p_off,
              'id_shift', x.id_shift + p_off, 'id_enterprise', p_dst))).*
        FROM serving.downtime_events_resolved x
       WHERE x.id_enterprise = p_src AND x.ts_event >= m AND x.ts_event < least(m + interval '1 month', w_from)
         AND NOT EXISTS (SELECT 1 FROM serving.downtime_events_resolved d
                          WHERE d.id_enterprise = p_dst AND d.ts_event = x.ts_event AND d.id_equipment = x.id_equipment + p_off);
      IF p_commit THEN COMMIT; SET LOCAL session_replication_role = replica; END IF;
    END LOOP;
    RAISE NOTICE 'history resolved downtimes filled';
  END IF;
END $$;

COMMENT ON PROCEDURE ops.sandbox_reflect(int, int, int, interval, boolean, text, text, boolean) IS
  'Reflect CPACK (src) onto its sandbox twin (dst) on the analytics plane: config upsert + extras delete, mutable data reset (events window, manual events, POs), optional history fill. Then call serving.refresh_downtime_events_resolved for the window. See db/migrations/t-sandbox-reflection.';
