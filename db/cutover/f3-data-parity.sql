-- =====================================================================
-- f3-data-parity.sql  —  STAGING F1 (packiot) -> F3 (packiot_analytics)
-- =====================================================================
-- PURPOSE
--   Make F3 (packiot_analytics) DATA-COMPLETE for CONFIG + AUTH + HISTORY
--   before edge-api flips its reads/writes + auth to F3 on STAGING.
--   F1 (packiot) is the current master; edge-api authenticates callers via
--   enterprises.api_key and resolves operator/user login via users. If F3 is
--   missing a tenant's api_key or a user, every request from that tenant
--   401/403s after the flip. This script closes that gap idempotently.
--
-- RUN CONTEXT
--   Run AGAINST F3:  psql -d packiot_analytics -f db/cutover/f3-data-parity.sql
--   Uses dblink (same server) to pull from F1 (dbname=packiot).
--   Requires the dblink extension (already installed on staging).
--
-- SAFETY / SCOPE
--   * CONFIG + AUTH + HISTORY ONLY.  NEVER touches pure telemetry
--     (equipment_values, *_1min/_1hour caggs, uns_*, area/site/equipment_runtime_*).
--   * Idempotent: re-running produces ZERO changes (INSERT ... WHERE NOT EXISTS
--     on the natural/PK key; UPDATE ... WHERE row IS DISTINCT FROM source).
--   * Column-drift resilient: each table copies only the INTERSECTION of columns
--     present in BOTH planes (so F3-only cols like packml_register.device_key or
--     the *_history temporal cols valid_from/valid_to are left untouched).
--   * SERIAL-PK SAFE: for NATURAL-KEY syncs (match key != PK, e.g.
--     packml_register matched on packml_topic) the serial PK is NEVER written —
--     not on UPDATE (would stamp F1's id onto an F3 row -> PK collision) and not
--     on INSERT (let F3's own sequence assign; setval afterwards). PK-matched
--     tables (shifts/shift_hours/...) keep inserting with their aligned ids.
--   * VOLATILE-COLUMN SAFE: the _exclude arg lets a config table skip its
--     live-updated telemetry-cache columns. packml_register carries last-sample
--     fields (timestamp/value/signal_quality/ts_quality/sparkplug_json) that the
--     decode path rewrites continuously; syncing them from F1 would churn a LIVE
--     tenant (CPACK/ent-3 is live on F3), so they are excluded — routing/config
--     columns only.
--   * Reversibility intentionally NOT handled (staging).
--
-- ORDER (FK-safe: parents before children)
--   enterprises -> user_roles -> users
--   -> sites -> areas -> equipments -> packml_register
--   -> shifts -> shift_hours -> teams -> production_targets -> language_packs
--   -> (history) production_orders -> production_orders_runtime
--      -> equipment_events -> equipment_events_man -> user_logs
--
-- PHASES
--   A  AUTH-CRITICAL (applied on staging): enterprises, user_roles, users.
--   B  CONFIG (applied on staging): sites..language_packs.
--   C  HISTORY (bulk, DEFERRED to the coordinated cutover window).
--   Sequence fix-up (setval) runs after A+B so edge-api's next INSERT does not
--   collide with an id copied from F1.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS dblink;
CREATE SCHEMA IF NOT EXISTS cutover;

-- Audit log of every sync run (idempotency proof lives here across runs).
CREATE TABLE IF NOT EXISTS cutover.parity_log (
    id            bigserial PRIMARY KEY,
    ran_at        timestamptz NOT NULL DEFAULT now(),
    tbl           text        NOT NULL,
    match_keys    text        NOT NULL,
    rows_inserted bigint      NOT NULL,
    rows_updated  bigint      NOT NULL,
    shared_cols   text        NOT NULL
);

-- ---------------------------------------------------------------------
-- cutover.sync_table(tbl, match_keys[], do_update, exclude[])
--   Generic idempotent F1->F3 upsert for one table.
--   * tbl        : table name (same in both planes)
--   * match_keys : natural/PK key columns used to detect existence.
--                  Use the PRIMARY KEY where PK ids align across planes;
--                  use a NATURAL key where the serial PK has diverged
--                  (e.g. packml_register -> {packml_topic}).
--   * do_update  : also UPDATE non-key columns that differ (default true).
--   * exclude    : columns to NEVER write (volatile/telemetry-cache).
--
--   Column policy:
--     protect  = (PK columns NOT in match_keys)  +  exclude
--     insert   = shared - protect                (serial PK omitted -> seq assigns)
--     set      = shared - match_keys - protect
--   Writes cutover.parity_log; RAISES NOTICE with counts.
-- ---------------------------------------------------------------------
-- Drop any earlier overload so the defaulted-arg call sites are unambiguous.
DROP FUNCTION IF EXISTS cutover.sync_table(text, text[], boolean);

CREATE OR REPLACE FUNCTION cutover.sync_table(
    _tbl        text,
    _match_keys text[],
    _do_update  boolean DEFAULT true,
    _exclude    text[]  DEFAULT '{}'
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
    _shared      text[];
    _pkcols      text[];
    _protect     text[];
    _ins_cols    text[];
    _set_cols    text[];
    _ins_coldef  text; _ins_collist text;
    _upd_cols    text[];
    _upd_coldef  text; _upd_collist text;
    _set_clause  text; _join_cond text; _lhs text; _rhs text;
    _sql         text;
    _ins bigint := 0; _upd bigint := 0;
    k text;
BEGIN
    -- shared columns (present in BOTH planes), ordered by F3 attnum
    SELECT array_agg(f3.column_name ORDER BY f3.ordinal_position) INTO _shared
    FROM information_schema.columns f3
    JOIN dblink('dbname=packiot',
             format($q$SELECT column_name FROM information_schema.columns
                       WHERE table_schema='public' AND table_name=%L$q$, _tbl))
         AS f1(column_name text) USING (column_name)
    WHERE f3.table_schema='public' AND f3.table_name=_tbl;

    IF _shared IS NULL THEN
        RAISE NOTICE '[skip] %: no shared columns (table missing in one plane)', _tbl;
        RETURN;
    END IF;

    -- primary key columns of the F3 table
    SELECT array_agg(a.attname) INTO _pkcols
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid=_tbl::regclass AND i.indisprimary;

    -- never write: PK columns not used as a match key (serial drift) + explicit excludes
    _protect := ARRAY(SELECT x FROM unnest(coalesce(_pkcols,'{}')) x
                       WHERE NOT (x = ANY(_match_keys)))
                || coalesce(_exclude,'{}');

    _ins_cols := ARRAY(SELECT x FROM unnest(_shared) x WHERE NOT (x = ANY(_protect)));
    _set_cols := ARRAY(SELECT x FROM unnest(_shared) x
                        WHERE NOT (x = ANY(_match_keys)) AND NOT (x = ANY(_protect)));

    -- typed defs for the INSERT projection
    SELECT string_agg(quote_ident(attname)||' '||format_type(atttypid,atttypmod), ', ' ORDER BY attnum),
           string_agg(quote_ident(attname), ', ' ORDER BY attnum)
      INTO _ins_coldef, _ins_collist
    FROM pg_attribute
    WHERE attrelid=_tbl::regclass AND attname = ANY(_ins_cols) AND attnum>0 AND NOT attisdropped;

    -- join on the match keys
    _join_cond := '';
    FOREACH k IN ARRAY _match_keys LOOP
        _join_cond := _join_cond || CASE WHEN _join_cond='' THEN '' ELSE ' AND ' END ||
            format('t.%I IS NOT DISTINCT FROM s.%I', k, k);
    END LOOP;

    -- INSERT rows present in F1, absent in F3 (by match keys); serial PK omitted
    _sql := format($i$
        INSERT INTO %1$I (%2$s)
        SELECT %2$s FROM dblink('dbname=packiot', %3$L) AS s(%4$s)
        WHERE NOT EXISTS (SELECT 1 FROM %1$I t WHERE %5$s)
    $i$, _tbl, _ins_collist, format('SELECT %s FROM %I', _ins_collist, _tbl),
         _ins_coldef, _join_cond);
    EXECUTE _sql;
    GET DIAGNOSTICS _ins = ROW_COUNT;

    -- UPDATE divergent non-key, non-protected columns for rows in both
    IF _do_update AND _set_cols IS NOT NULL AND array_length(_set_cols,1) > 0 THEN
        _upd_cols := ARRAY(SELECT DISTINCT x FROM unnest(_match_keys || _set_cols) x);
        SELECT string_agg(quote_ident(attname)||' '||format_type(atttypid,atttypmod), ', ' ORDER BY attnum),
               string_agg(quote_ident(attname), ', ' ORDER BY attnum)
          INTO _upd_coldef, _upd_collist
        FROM pg_attribute
        WHERE attrelid=_tbl::regclass AND attname = ANY(_upd_cols) AND attnum>0 AND NOT attisdropped;

        SELECT string_agg(format('%I = s.%I', x, x), ', '),
               string_agg(format('t.%I', x), ', '),
               string_agg(format('s.%I', x), ', ')
          INTO _set_clause, _lhs, _rhs
        FROM unnest(_set_cols) x;

        _sql := format($u$
            UPDATE %1$I t SET %2$s
              FROM dblink('dbname=packiot', %3$L) AS s(%4$s)
             WHERE %5$s AND ( (%6$s) IS DISTINCT FROM (%7$s) )
        $u$, _tbl, _set_clause, format('SELECT %s FROM %I', _upd_collist, _tbl),
             _upd_coldef, _join_cond, _lhs, _rhs);
        EXECUTE _sql;
        GET DIAGNOSTICS _upd = ROW_COUNT;
    END IF;

    INSERT INTO cutover.parity_log(tbl, match_keys, rows_inserted, rows_updated, shared_cols)
    VALUES (_tbl, array_to_string(_match_keys, ','), _ins, _upd, array_to_string(_ins_cols, ','));
    RAISE NOTICE '[sync] %  keys=%  inserted=%  updated=%',
        _tbl, array_to_string(_match_keys, ','), _ins, _upd;
END;
$fn$;

-- ---------------------------------------------------------------------
-- cutover.fix_sequences() — after inserting rows with explicit (F1) ids,
--   advance each table's serial sequence to max(pk)+1 so edge-api's next
--   INSERT does not collide. Idempotent. Tables with no serial PK
--   (production_targets composite, language_packs=language_tag, user_roles
--   non-serial) are skipped automatically.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cutover.fix_sequences(_tables text[]) RETURNS void
LANGUAGE plpgsql AS $seq$
DECLARE t text; pk text; seq text; newval bigint;
BEGIN
    FOREACH t IN ARRAY _tables LOOP
        SELECT a.attname INTO pk
        FROM pg_index i JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=ANY(i.indkey)
        WHERE i.indrelid=t::regclass AND i.indisprimary
        LIMIT 1;                                   -- single-column PKs only
        IF pk IS NULL THEN CONTINUE; END IF;
        seq := pg_get_serial_sequence('public.'||t, pk);
        IF seq IS NULL THEN CONTINUE; END IF;      -- no serial/identity
        EXECUTE format('SELECT coalesce(max(%I),0)+1 FROM %I', pk, t) INTO newval;
        PERFORM setval(seq, newval, false);
        RAISE NOTICE '[seq] % -> % = %', t, seq, newval;
    END LOOP;
END;
$seq$;

-- =====================================================================
-- PHASE A — AUTH-CRITICAL (the 401/403 gate).  APPLIED on staging.
--   NOTE: users.operator_pw_hash must exist in F3 (schema agent added it);
--   the intersection copy includes it. Re-run this phase if schema is rebuilt.
-- =====================================================================
SELECT cutover.sync_table('enterprises', ARRAY['id_enterprise']);
SELECT cutover.sync_table('user_roles',  ARRAY['id_user_role']);

-- users: bespoke — F3 carries SECONDARY unique keys (id_user_firebase,
-- id_user_cognito) and the users PK has DRIFTED (F1 id_user=3 "0001_os2" is the
-- SAME person as F3 id_user=1 — same firebase+email). A blind id_user upsert
-- would duplicate that identity and violate uid_firebase_un. INSERT only F1
-- users not represented by ANY identity key (coalescing empty firebase to NULL —
-- uid_firebase_un is NON-partial, so multiple '' collide but multiple NULLs are
-- allowed); UPDATE only NON-identity columns (notably operator_pw_hash).
DO $users$
DECLARE _ins bigint; _upd bigint;
BEGIN
    INSERT INTO users (id_user, user_email, user_name, id_enterprise, id_user_firebase,
                       phone_number, user_roles, timezone, languages, user_menu,
                       internal_user, active, id_user_cognito, operator_pw_hash)
    SELECT s.id_user, s.user_email, s.user_name, s.id_enterprise,
           NULLIF(s.id_user_firebase,'') AS id_user_firebase,
           s.phone_number, s.user_roles, s.timezone, s.languages, s.user_menu,
           s.internal_user, s.active, s.id_user_cognito, s.operator_pw_hash
    FROM dblink('dbname=packiot',
      $q$SELECT id_user,user_email,user_name,id_enterprise,id_user_firebase,phone_number,
                user_roles,timezone,languages,user_menu,internal_user,active,
                id_user_cognito,operator_pw_hash FROM users$q$)
      AS s(id_user int,user_email varchar,user_name varchar,id_enterprise int,
           id_user_firebase varchar,phone_number varchar,user_roles int,timezone varchar,
           languages varchar,user_menu jsonb,internal_user boolean,active boolean,
           id_user_cognito text,operator_pw_hash text)
    WHERE NOT EXISTS (SELECT 1 FROM users t WHERE t.id_user = s.id_user)
      AND NOT EXISTS (SELECT 1 FROM users t
                        WHERE NULLIF(s.id_user_firebase,'') IS NOT NULL
                          AND t.id_user_firebase = s.id_user_firebase)
      AND NOT EXISTS (SELECT 1 FROM users t
                        WHERE s.id_user_cognito IS NOT NULL
                          AND t.id_user_cognito = s.id_user_cognito);
    GET DIAGNOSTICS _ins = ROW_COUNT;

    UPDATE users t SET
        user_email       = s.user_email,
        user_name        = s.user_name,
        id_enterprise    = s.id_enterprise,
        phone_number     = s.phone_number,
        user_roles       = s.user_roles,
        timezone         = s.timezone,
        languages        = s.languages,
        user_menu        = s.user_menu,
        internal_user    = s.internal_user,
        active           = s.active,
        operator_pw_hash = s.operator_pw_hash
    FROM dblink('dbname=packiot',
      $q$SELECT id_user,user_email,user_name,id_enterprise,phone_number,user_roles,
                timezone,languages,user_menu,internal_user,active,operator_pw_hash FROM users$q$)
      AS s(id_user int,user_email varchar,user_name varchar,id_enterprise int,
           phone_number varchar,user_roles int,timezone varchar,languages varchar,
           user_menu jsonb,internal_user boolean,active boolean,operator_pw_hash text)
    WHERE t.id_user = s.id_user
      AND ( (t.user_email,t.user_name,t.id_enterprise,t.phone_number,t.user_roles,
             t.timezone,t.languages,t.user_menu,t.internal_user,t.active,t.operator_pw_hash)
            IS DISTINCT FROM
            (s.user_email,s.user_name,s.id_enterprise,s.phone_number,s.user_roles,
             s.timezone,s.languages,s.user_menu,s.internal_user,s.active,s.operator_pw_hash) );
    GET DIAGNOSTICS _upd = ROW_COUNT;

    INSERT INTO cutover.parity_log(tbl,match_keys,rows_inserted,rows_updated,shared_cols)
    VALUES ('users','id_user|+firebase/cognito guard',_ins,_upd,'bespoke');
    RAISE NOTICE '[sync] users (bespoke) inserted=% updated=%', _ins, _upd;
END;
$users$;

-- =====================================================================
-- PHASE B — CONFIG (topology + shifts + targets + i18n packs). APPLIED on staging.
--   packml_register: NATURAL key packml_topic (serial PK id_packml_register has
--   DIVERGED between planes). The function omits id_packml_register from both
--   INSERT and SET, and _exclude drops the live telemetry-cache columns so a
--   LIVE tenant (CPACK/ent-3) is not churned — routing/config columns only.
-- =====================================================================
SELECT cutover.sync_table('sites',              ARRAY['id_site']);
SELECT cutover.sync_table('areas',              ARRAY['id_area']);
SELECT cutover.sync_table('equipments',         ARRAY['id_equipment']);

-- packml_register: bespoke, INSERT-ONLY (no UPDATE).  Two hazards forced this:
--   (1) The serial PK id_packml_register has DIVERGED between planes, so the
--       natural key is packml_topic.
--   (2) F1 stores DUPLICATE rows per packml_topic (an active=true AND an
--       active=false row — F1's unique index on packml_topic is PARTIAL,
--       WHERE active). Those inactive twins often carry a DIFFERENT id_equipment.
--       An UPDATE ... FROM matched on packml_topic would pick a source row
--       non-deterministically and could stamp the wrong id_equipment / flip
--       active=false onto a LIVE row — CPACK (ent-3) runs on F3, so that breaks
--       decode.  Safety dry-run proved would_update=0 for EVERY tenant and
--       ent-3 would_insert=0, so INSERT-ONLY loses nothing and cannot touch a
--       single existing (CPACK) row.
--   We de-dup with DISTINCT ON (packml_topic) preferring the active row, and
--   omit id_packml_register so F3's sequence assigns a fresh, collision-free id.
--   F3 remains authoritative for existing packml_register config; only genuinely
--   MISSING topics (Bispharma 10, Bisnago 10, OPS-TEST 10, sandbox 35) are added.
DO $packml$
DECLARE _ins bigint;
BEGIN
    INSERT INTO packml_register
        (packml_topic, mqtt_topic, id_equipment, id_site, id_area, id_enterprise,
         id_infeedcounter, id_outfeedcounter, id_rejectcounter, active, attributed,
         id_unit, line_unit_seq, device_nm)
    SELECT DISTINCT ON (s.packml_topic)
         s.packml_topic, s.mqtt_topic, s.id_equipment, s.id_site, s.id_area, s.id_enterprise,
         s.id_infeedcounter, s.id_outfeedcounter, s.id_rejectcounter, s.active, s.attributed,
         s.id_unit, s.line_unit_seq, s.device_nm
    FROM dblink('dbname=packiot',
      $q$SELECT packml_topic,mqtt_topic,id_equipment,id_site,id_area,id_enterprise,
                id_infeedcounter,id_outfeedcounter,id_rejectcounter,active,attributed,
                id_unit,line_unit_seq,device_nm FROM packml_register$q$)
      AS s(packml_topic varchar, mqtt_topic varchar, id_equipment int, id_site int, id_area int,
           id_enterprise int, id_infeedcounter int, id_outfeedcounter int, id_rejectcounter int,
           active boolean, attributed boolean, id_unit int, line_unit_seq varchar, device_nm varchar)
    WHERE NOT EXISTS (SELECT 1 FROM packml_register t WHERE t.packml_topic = s.packml_topic)
    ORDER BY s.packml_topic, s.active DESC NULLS LAST;   -- prefer the active twin
    GET DIAGNOSTICS _ins = ROW_COUNT;

    INSERT INTO cutover.parity_log(tbl,match_keys,rows_inserted,rows_updated,shared_cols)
    VALUES ('packml_register','packml_topic (INSERT-ONLY, dedup)',_ins,0,'config cols; volatile+PK excluded');
    RAISE NOTICE '[sync] packml_register (INSERT-ONLY) inserted=% updated=0', _ins;
END;
$packml$;

SELECT cutover.sync_table('shifts',             ARRAY['id_shift']);
SELECT cutover.sync_table('shift_hours',        ARRAY['id_shift_hour']);
SELECT cutover.sync_table('teams',              ARRAY['id_team']);
SELECT cutover.sync_table('production_targets', ARRAY['id_equipment','id_site']);    -- composite PK
SELECT cutover.sync_table('language_packs',     ARRAY['language_tag']);              -- NATURAL key (PK, no serial)

-- Advance serial sequences on every table that received explicit-id inserts.
SELECT cutover.fix_sequences(ARRAY[
    'enterprises','user_roles','users',
    'sites','areas','equipments','packml_register',
    'shifts','shift_hours','teams']);

-- =====================================================================
-- PHASE C — HISTORY (BULK). DEFERRED to the coordinated cutover window.
--   DECISION: migrate ALL history for report continuity (Superset / reports
--   read F3 post-cutover; a forward-only cut blanks every historical dashboard
--   and OEE trend). Composite natural keys avoid serial-PK divergence.
--   Telemetry (equipment_values, caggs, uns_*) is deliberately EXCLUDED.
-- =====================================================================
-- SELECT cutover.sync_table('production_orders',         ARRAY['id_production_order']);
-- SELECT cutover.sync_table('production_orders_runtime', ARRAY['id_production_order_runtime']);
-- SELECT cutover.sync_table('equipment_events',          ARRAY['id_equipment','ts_event']);
-- SELECT cutover.sync_table('equipment_events_man',      ARRAY['id_equipment_event']);
-- SELECT cutover.sync_table('user_logs',                 ARRAY['id_user_logs']);
-- SELECT cutover.fix_sequences(ARRAY['production_orders','production_orders_runtime',
--                                    'equipment_events_man','user_logs']);

-- Post-run: SELECT * FROM cutover.parity_log ORDER BY id;
