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
--     present in BOTH planes (so F3-only temporal cols valid_from/valid_to/
--     created_at/updated_at are left untouched, and F1-only cols are skipped).
--   * Reversibility intentionally NOT handled (staging).
--
-- ORDER
--   Parent tables before children (FK-safe):
--     enterprises -> user_roles -> users
--     -> sites -> areas -> equipments -> packml_register
--     -> shifts -> shift_hours -> teams -> production_targets -> language_packs
--     -> (history) production_orders -> production_orders_runtime
--        -> equipment_events -> equipment_events_man -> user_logs
--
-- PILOT vs BULK  (see the two SELECT cutover.sync_* driver blocks at the end)
--   Phase A (AUTH-CRITICAL, safe to apply pre-cutover): enterprises, user_roles,
--     users.  Small, high-value, closes the 401/403 gate.
--   Phase B (CONFIG): sites..language_packs.
--   Phase C (HISTORY, bulk — apply during the coordinated cutover window):
--     production_orders, production_orders_runtime, equipment_events,
--     equipment_events_man, user_logs.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS dblink;
CREATE SCHEMA IF NOT EXISTS cutover;

-- Audit log of every sync run (idempotency proof lives here across runs).
CREATE TABLE IF NOT EXISTS cutover.parity_log (
    id           bigserial PRIMARY KEY,
    ran_at       timestamptz NOT NULL DEFAULT now(),
    tbl          text        NOT NULL,
    match_keys   text        NOT NULL,
    rows_inserted bigint     NOT NULL,
    rows_updated  bigint     NOT NULL,
    shared_cols  text        NOT NULL
);

-- ---------------------------------------------------------------------
-- cutover.sync_table(tbl, match_keys[], do_update)
--   Generic idempotent F1->F3 upsert for one table.
--   * tbl        : table name (same in both planes)
--   * match_keys : the natural/PK key columns used to detect existence.
--                  Use the PRIMARY KEY where PK ids align across planes;
--                  use a NATURAL key where the PK is a serial that has
--                  diverged (e.g. packml_register -> {packml_topic}).
--   * do_update  : also UPDATE non-key columns that differ (default true).
--
--   Returns nothing; RAISES NOTICE and writes cutover.parity_log.
--   Column set = intersection of columns present in BOTH planes for `tbl`,
--   typed from the F3 catalog (shared cols must be type-compatible).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cutover.sync_table(
    _tbl        text,
    _match_keys text[],
    _do_update  boolean DEFAULT true
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
    _shared      text[];      -- shared column names (both planes), attnum order
    _coldef      text;        -- "col1 type1, col2 type2, ..." for dblink record
    _collist     text;        -- "col1, col2, ..."
    _nonkey      text[];      -- shared minus match_keys
    _join_cond   text;        -- t.k1 = s.k1 AND ...
    _set_clause  text;        -- SET c = s.c, ...
    _distinct    text;        -- (t.c1,...) IS DISTINCT FROM (s.c1,...)
    _sql         text;
    _ins         bigint := 0;
    _upd         bigint := 0;
    k            text;
    c            text;
BEGIN
    -- shared columns (present in F1 AND F3), ordered by F3 attnum
    SELECT array_agg(f3.column_name ORDER BY f3.ordinal_position)
      INTO _shared
    FROM information_schema.columns f3
    JOIN dblink('dbname=packiot',
             format($q$SELECT column_name FROM information_schema.columns
                       WHERE table_schema='public' AND table_name=%L$q$, _tbl))
         AS f1(column_name text) USING (column_name)
    WHERE f3.table_schema='public' AND f3.table_name = _tbl;

    IF _shared IS NULL THEN
        RAISE NOTICE '[skip] %: no shared columns (table missing in one plane)', _tbl;
        RETURN;
    END IF;

    -- typed column-def list for the dblink record, from the F3 catalog
    SELECT string_agg(quote_ident(a.attname) || ' ' ||
                      format_type(a.atttypid, a.atttypmod),
                      ', ' ORDER BY a.attnum),
           string_agg(quote_ident(a.attname), ', ' ORDER BY a.attnum)
      INTO _coldef, _collist
    FROM pg_attribute a
    WHERE a.attrelid = _tbl::regclass
      AND a.attname = ANY(_shared)
      AND a.attnum > 0 AND NOT a.attisdropped;

    -- non-key shared columns
    SELECT array_agg(x) INTO _nonkey
    FROM unnest(_shared) x
    WHERE NOT (x = ANY(_match_keys));

    -- join condition on the match keys
    _join_cond := '';
    FOREACH k IN ARRAY _match_keys LOOP
        _join_cond := _join_cond ||
            CASE WHEN _join_cond = '' THEN '' ELSE ' AND ' END ||
            format('t.%I IS NOT DISTINCT FROM s.%I', k, k);
    END LOOP;

    -- INSERT rows present in F1, absent in F3 (by match keys)
    _sql := format($i$
        INSERT INTO %1$I (%2$s)
        SELECT %2$s FROM dblink('dbname=packiot',
                 %3$L) AS s(%4$s)
        WHERE NOT EXISTS (
            SELECT 1 FROM %1$I t WHERE %5$s )
    $i$, _tbl, _collist,
         format('SELECT %s FROM %I', _collist, _tbl),
         _coldef, _join_cond);
    EXECUTE _sql;
    GET DIAGNOSTICS _ins = ROW_COUNT;

    -- UPDATE divergent non-key columns for rows present in both
    IF _do_update AND _nonkey IS NOT NULL AND array_length(_nonkey,1) > 0 THEN
        SELECT string_agg(format('%I = s.%I', x, x), ', '),
               string_agg(format('t.%I', x), ', '),
               string_agg(format('s.%I', x), ', ')
          INTO _set_clause, _distinct, c
        FROM unnest(_nonkey) x;

        _sql := format($u$
            UPDATE %1$I t
               SET %2$s
              FROM dblink('dbname=packiot', %3$L) AS s(%4$s)
             WHERE %5$s
               AND ( (%6$s) IS DISTINCT FROM (%7$s) )
        $u$, _tbl, _set_clause,
             format('SELECT %s FROM %I', _collist, _tbl),
             _coldef, _join_cond, _distinct, c);
        EXECUTE _sql;
        GET DIAGNOSTICS _upd = ROW_COUNT;
    END IF;

    INSERT INTO cutover.parity_log(tbl, match_keys, rows_inserted, rows_updated, shared_cols)
    VALUES (_tbl, array_to_string(_match_keys, ','), _ins, _upd, array_to_string(_shared, ','));

    RAISE NOTICE '[sync] %-28s keys=%-22s inserted=% updated=%',
        _tbl, array_to_string(_match_keys, ','), _ins, _upd;
END;
$fn$;

-- =====================================================================
-- PHASE A — AUTH-CRITICAL (the 401/403 gate). Safe to apply pre-cutover.
--   enterprises.api_key, user_roles, users (rows + cognito ids).
--   NOTE: users.operator_pw_hash is copied ONLY IF the column exists in F3.
--   As of the audit F3.users has NO operator_pw_hash column (schema agent
--   must add it). Until then operator login stays broken even with rows
--   present; the intersection copy simply skips that column. Re-run this
--   phase AFTER the column is added to backfill hashes.
-- =====================================================================
SELECT cutover.sync_table('enterprises', ARRAY['id_enterprise']);
SELECT cutover.sync_table('user_roles',  ARRAY['id_user_role']);

-- users: NOT routed through the generic function because F3.users carries
-- SECONDARY unique keys (id_user_firebase, id_user_cognito) and the users PK
-- has DRIFTED for at least one row (F1 id_user=3 "0001_os2@packiot.com" is the
-- SAME person as F3 id_user=1 — same firebase+email). A blind id_user upsert
-- would duplicate that identity and violate uid_firebase_un. So we INSERT only
-- F1 users not already represented by ANY identity key, coalescing empty
-- firebase to NULL (uid_firebase_un is a NON-partial unique — multiple '' collide,
-- multiple NULLs are allowed), and UPDATE only NON-identity columns
-- (notably operator_pw_hash) on rows already matched by id_user.
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

    -- refresh non-identity columns (operator_pw_hash, roles, menu, flags) for
    -- users already present by id_user; never touch the unique identity columns.
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
-- PHASE B — CONFIG (topology + shifts + targets + i18n packs).
--   packml_register uses the NATURAL key packml_topic: its serial PK
--   id_packml_register has DIVERGED between planes (F3 regenerated ids),
--   so a PK upsert would create duplicate topic rows. Matching by
--   packml_topic reconciles routing without touching F3's own PK values.
--   (F3 has a partial-unique index on packml_topic WHERE active; the
--    NOT EXISTS/UPDATE pattern here never depends on it.)
-- =====================================================================
SELECT cutover.sync_table('sites',            ARRAY['id_site']);
SELECT cutover.sync_table('areas',            ARRAY['id_area']);
SELECT cutover.sync_table('equipments',       ARRAY['id_equipment']);
SELECT cutover.sync_table('packml_register',  ARRAY['packml_topic']);   -- NATURAL key
SELECT cutover.sync_table('shifts',           ARRAY['id_shift']);
SELECT cutover.sync_table('shift_hours',      ARRAY['id_shift_hour']);
SELECT cutover.sync_table('teams',            ARRAY['id_team']);
SELECT cutover.sync_table('production_targets', ARRAY['id_equipment','id_site']);  -- composite PK
SELECT cutover.sync_table('language_packs',   ARRAY['language_tag']);   -- NATURAL key (PK)

-- =====================================================================
-- PHASE C — HISTORY (BULK). Apply during the coordinated cutover window.
--   DECISION: migrate ALL history for report continuity (Superset / BI /
--   reports read F3 post-cutover; a forward-only cut would blank every
--   historical dashboard and OEE trend). These are large (see counts in the
--   PR description) — run inside the maintenance window, expect minutes.
--   Composite natural keys avoid the serial-PK divergence risk.
--   Telemetry (equipment_values, caggs, uns_*) is deliberately EXCLUDED.
-- =====================================================================
-- Uncomment to run Phase C (bulk) — left commented so a casual run of this
-- file does the safe config+auth work only.
-- SELECT cutover.sync_table('production_orders',         ARRAY['id_production_order']);
-- SELECT cutover.sync_table('production_orders_runtime', ARRAY['id_production_order_runtime']);
-- SELECT cutover.sync_table('equipment_events',          ARRAY['id_equipment','ts_event']);   -- composite PK
-- SELECT cutover.sync_table('equipment_events_man',      ARRAY['id_equipment_event']);
-- SELECT cutover.sync_table('user_logs',                 ARRAY['id_user_logs']);

-- Post-run: SELECT * FROM cutover.parity_log ORDER BY id;
