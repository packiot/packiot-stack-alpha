#!/usr/bin/env python3
"""Promotion transplant — generate every phase file from three inputs, so promotion day re-runs on FRESH inputs.

  build.py <workdir>

<workdir> must contain:
  stg-schema.dump   pg_dump --schema-only -Fc of staging packiot_analytics (the target schema, by construction)
  cat-stg.json      scripts/promotion/transplant/catalog.sql run on staging      (READ ONLY)
  cat-prod.json     the same query run on the prod DB                            (READ ONLY)
Writes <workdir>/out/: pre.sql 02-hypertables-caggs.sql 03-hyper-keys.sql views.sql 04-data-copy.sql 05-repairs.sql
post.sql 06-checks.sql 07-data.sql [07b-cpack-config.sql 07b-cpack-config-diff.sql] 08-logic.sql 90-comments-grants.sql 10-policies.sql 11-refresh.sql
00-roles.sql 00-joblog.sql 01-extensions.sql (+ xplant.sh copied). TimescaleDB-optional: a TS-free staging (ADR-0063) yields a TS-free target.

Method and every rule below: docs/adr/reference/production-promotion-transplant-runbook.md. Each rule names the rehearsal
finding (2026-10-08, isolated clone of the prod DB) that made it necessary.
Needs: docker (postgres:16-alpine for pg_restore), git (origin/staging for the phase-D migration files).
"""
import json, os, re, shutil, subprocess, sys

W = sys.argv[1]
OUT = os.path.join(W, 'out')
os.makedirs(OUT, exist_ok=True)
HERE = os.path.dirname(os.path.abspath(__file__))
S = json.load(open(os.path.join(W, 'cat-stg.json')))
P = json.load(open(os.path.join(W, 'cat-prod.json')))


def staging_only(s, n):
    """Objects that exist only for staging's own operation (backups, backfill tooling, sandbox twin, mirror cursor).

    silver.equipment_events_cpac_shadow is NOT staging-only any more (promotion 2026-10, B5/B11): prod's stream-engine
    runs ent 3's CPAC deriver in SHADOW mode like staging (CPAC_EVENT_ENTERPRISES=3, live list empty), and it writes
    that table — without it the deriver fails every tick. It is created empty (no prod source). ops.mirror_replay_cursor
    stays excluded: the prod legacy-replicator creates it IF NOT EXISTS and must COLD-start (BACKFILL_SINCE), so
    staging's cursor row must never travel. `<table>__old` = a pre-swap copy kept on staging for a week (ADR-0065 P3a
    silver.equipment_metrics_1min__old, 2026-10-16) — rollback material for staging only."""
    return (n.startswith('_bkp') or n.endswith('__old') or (s == 'ops' and (n.startswith('_') or n.startswith('bf') or n.startswith('sandbox')))
            or (s, n) in {('ops', 'mirror_replay_cursor')})


CAGGS = {(c['s'], c['n']): c for c in (S['caggs'] or [])}   # json_agg of nothing = null (TS-free staging)
HYPERTABLES = [t for t in S['tables'] if t.get('ht') and not staging_only(t['s'], t['n'])]
HT_NAMES = {f"{t['s']}.{t['n']}" for t in HYPERTABLES}
# ADR-0063 (2026-10-15): staging dropped TimescaleDB — hypertables became native RANGE-partitioned tables (ops.pc_*) and
# the caggs plain tables written by the rollup tick. With no extension on staging, HYPERTABLES/CAGGS are empty and every
# TimescaleDB step below generates nothing; the partitions travel in pre-data like any table (pg_dump: CREATE TABLE +
# TABLE ATTACH). The target DB then never gets CREATE EXTENSION timescaledb (xplant.sh `create` reads 01-extensions.sql).
STAGING_TS = 'timescaledb' in (S.get('extensions') or []) or bool(HYPERTABLES or CAGGS)
PARTITIONS = {(t['s'], t['n']) for t in S['tables'] if t.get('parent')}
PARTITIONED = [t for t in S['tables'] if t.get('part') and not staging_only(t['s'], t['n'])]
# column renames between prod and staging that a name-based copy would otherwise lose (t224, t243)
COLUMN_RENAMES = {('core', 'production_orders'): [('oee_q', 'oee_quality'), ('oee_a', 'oee_availability'), ('oee_p', 'oee_performance')],
                  ('core', 'topic_routing'): [('id_topic_route', 'id_packml_register')]}
TABLE_RENAMES = {'topic_routing': 'packml_register'}   # staging was BORN with this rename (F3 snapshot); no migration does it


def write(name, text):
    # newline='' everywhere: staging's function bodies contain CRLF; universal-newline translation would rewrite them
    open(os.path.join(OUT, name), 'w', newline='').write(text)


def pg_restore(listfile, outfile):
    subprocess.run(['docker', 'run', '--rm', '-v', f'{W}:/d', 'postgres:16-alpine', 'pg_restore', '-L', f'/d/out/{listfile}',
                    '-f', f'/d/out/{outfile}', '/d/stg-schema.dump'], check=True)


# ── 1. classify staging's TOC: pre-data (minus views) / views / post-data; skip Timescale internals, caggs, staging-only
toc = subprocess.run(['docker', 'run', '--rm', '-v', f'{W}:/d', 'postgres:16-alpine', 'pg_restore', '-l', '/d/stg-schema.dump'],
                     check=True, capture_output=True, text=True).stdout.splitlines(keepends=True)
POST = {'INDEX', 'CONSTRAINT', 'FK CONSTRAINT', 'TRIGGER', 'ROW SECURITY', 'POLICY', 'DEFAULT ACL', 'INDEX ATTACH'}
MULTI = ['FK CONSTRAINT', 'SEQUENCE OWNED BY', 'SEQUENCE SET', 'DEFAULT ACL', 'ROW SECURITY', 'COMMENT - SCHEMA', 'ACL - SCHEMA',
         'COMMENT - EXTENSION', 'EXTENSION -', 'SCHEMA -', 'MATERIALIZED VIEW', 'INDEX ATTACH', 'TABLE ATTACH', 'TABLE DATA']
pre, views, post, fns, cagg_acl = [], [], [], [], []
# pg_dump labels a view's ACL/COMMENT "ACL <schema> TABLE <view>": classify it by the catalog, or its GRANT runs in pre.sql
# before the view exists (selftest 2026-10-16: GRANT on silver.equipment_metrics_1min, a view since ADR-0065 P3a)
VIEW_NAMES = {(v['s'], v['n']) for v in (S['views'] or []) if v['kind'] == 'v'}
for line in toc:
    m = re.match(r'^(\d+); \d+ \d+ (.+)$', line.rstrip('\n'))
    if not m:
        continue
    rest = m.group(2)
    typ = next((t for t in MULTI if rest.startswith(t)), rest.split(' ')[0])
    tail = rest[len(typ):].strip().split(' ')
    sch = tail[0] if tail else ''
    name = ' '.join(tail[1:-1]) if len(tail) > 2 else (tail[1] if len(tail) > 1 else '')
    obj = name.split(' ')[-1] if typ in ('COMMENT', 'ACL') else name.split(' ')[0]
    # the object a COMMENT/ACL is ON: "FUNCTION f(a text, b int)" → f (an arg list has spaces, so `obj` is its last
    # word); "COLUMN tbl.col" → tbl (2026-10-16 dry run on the real TS-free staging: comments on staging-only bf_/sandbox_
    # functions and on a bi view's columns slipped through as pre.sql errors)
    _b = re.match(r'^(?:MATERIALIZED VIEW|[A-Z]+) "?([^"(\s]+)', name) if typ in ('COMMENT', 'ACL') else None
    base = (_b.group(1).split('.')[0] if name.startswith('COLUMN ') else _b.group(1)) if _b else obj.strip('"')
    if re.match(r'^(_timescaledb|timescaledb_)', sch) or ('timescaledb' in rest and typ.startswith('EXTENSION')):
        continue
    if typ in ('SCHEMA -', 'COMMENT - SCHEMA', 'ACL - SCHEMA') and re.search(r'(_timescaledb|timescaledb_)', rest):
        continue
    if staging_only(sch, obj.strip('"')) or staging_only(sch, name.split(' ')[0].strip('"')) or staging_only(sch, base):
        continue
    if (sch, obj) in CAGGS or (sch, name.split(' ')[0]) in CAGGS:
        if typ in ('ACL', 'COMMENT'):
            cagg_acl.append(line)   # 2026-10-14 rehearsal: skipping these lost every cagg GRANT (readapi_ro, stream_engine…)
        continue
    if typ in POST or (typ == 'COMMENT' and name.startswith(('CONSTRAINT ', 'INDEX ', 'TRIGGER ', 'POLICY '))):
        post.append(line)   # a comment on a post-data object runs after it exists (FK comments, 2026-10-16 dry run)
    elif typ == 'VIEW' or (typ in ('COMMENT', 'ACL') and (name.startswith('VIEW ') or (sch, base) in VIEW_NAMES)):
        views.append(line)
    else:
        pre.append(line)
        if typ in ('FUNCTION', 'PROCEDURE'):
            fns.append(line)
for n, lst in (('pre', pre), ('views', views), ('post', post), ('fn', fns), ('cagg_acl', cagg_acl)):
    open(os.path.join(OUT, f'{n}.list'), 'w').writelines(lst)
    pg_restore(f'{n}.list', f'{n}.raw.sql')
# drop grants to the personal staging account; split keeping line endings (CRLF bodies stay byte-identical)
strip_personal = lambda s: ''.join(l for l in re.split(r'(?<=\n)', s) if not re.search(r'"?dev@packiot\.com"?', l))
# staging-only tooling roles (CloudBeaver DB console): their grants never travel; the prod server has no such roles.
STAGING_ONLY_ROLES = ('cloudbeaver_ro', 'cloudbeaver_rw')
def _strip_tooling(sql):
    """Drop STAGING_ONLY_ROLES from GRANT/REVOKE/ALTER DEFAULT PRIVILEGES grantee lists; drop the line if none remain."""
    out = []
    for l in re.split(r'(?<=\n)', sql):
        m = re.match(r'^((?:GRANT|REVOKE|ALTER DEFAULT PRIVILEGES)\b.*?\b(?:TO|FROM) )([^;]+)(;.*)$', l, flags=re.S)
        if m and re.search(r'\b(' + '|'.join(STAGING_ONLY_ROLES) + r')\b', m.group(2)):
            keep = [r for r in m.group(2).split(',') if r.strip() not in STAGING_ONLY_ROLES]
            if not keep:
                continue
            l = m.group(1) + ','.join(keep).strip() + m.group(3)
        out.append(l)
    return ''.join(out)
_strip_personal = strip_personal
strip_personal = lambda s: _strip_tooling(_strip_personal(s))
pre_sql = strip_personal(open(os.path.join(OUT, 'pre.raw.sql'), newline='').read())
write('pre.sql', pre_sql)
views_sql = strip_personal(open(os.path.join(OUT, 'views.raw.sql'), newline='').read())
write('views.sql', views_sql)

# ── 0. SERVER-LEVEL prerequisites (promotion 2026-10-14 rehearsal). Both phases touch the LIVE prod SERVER (cluster-wide
#       objects), BEFORE the swap, while the old DB still serves: they are additive and inert for the old DB.
#   roles  (00-roles.sql)  — pg_dump --schema-only carries GRANTs/OWNERs to roles but never the roles themselves, nor their
#          ALTER ROLE … SET settings. Without this phase every GRANT to these roles fails in pre/post/grants ("role does
#          not exist") and the least-privilege services cannot log in. Idempotent (CREATE IF NOT EXISTS, ALTER to the target
#          shape). LOGIN with NO password: nobody can log in until scripts/ops/provision-db-role.py sets one from the host.
#          Attributes and settings = staging's live roles (pg_roles / pg_db_role_setting, 2026-10-14) = each role migration.
#   joblog (00-joblog.sql) — ADR-0063 A5: timescaledb.enable_job_execution_logging = on (ALTER SYSTEM, sighup, no restart;
#          t-timescale-job-execution-logging). Server-wide, so the transplant (one database) would never carry it.
ROLES = {  # name: (attributes, connection limit, {setting: value})
    'readapi_ro':        ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION INHERIT', -1, {}),
    'histgw_ro':         ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT', -1, {'app.tenant_id': '-1'}),
    'stream_engine':     ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT', 40, {'app.tenant_id': '-1'}),
    'legacy_replicator': ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT', 15, {}),
    'operator_gateway':  ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT', 10,
                          {'default_transaction_read_only': 'on', 'statement_timeout': '5s'}),
    'barcode_service':   ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT', 15, {'statement_timeout': '30s'}),
    # ADR-0064 prod-reflector (db/migrations/t-prod-reflector-roles, same attributes/limits/settings). Once that migration is on
    # staging, staging's dump GRANTs to both, so without them here the role gate below stops the build (go-live step 4).
    #   prod_reflector_ro — the one that MATTERS on prod: the reflector's read-only login to production (SELECT on the
    #                       reflected tables; password set on the prod app host by provision-db-role.py --service prod-reflector-ro).
    #   prod_reflector    — staging's write login; on prod it is created too, passwordless and never provisioned. Created rather
    #                       than its grants filtered because (a) go-live step 8a applies t-prod-reflector-roles to prod anyway
    #                       (idempotent; it creates both), so filtering here would be undone minutes later; (b) the ACL gate
    #                       (compare-acl.py) compares the target to staging and would then report every reflected table.
    #                       A role with no password cannot authenticate with scram/md5; NOBYPASSRLS with no app.tenant_id.
    'prod_reflector_ro': ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT', 6,
                          {'default_transaction_read_only': 'on', 'statement_timeout': '120s'}),
    'prod_reflector':    ('LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT', 8, {}),
}
# CLEAN-SERVER roles (Bispharma go-live 2026-10-15: production starts on a NEW, empty server). The old prod server already has
# these two (they came with prod's own history), so they were never in ROLES; a clean server has neither, and build.py stopped
# here. Created ONLY IF MISSING and never ALTERed: on a server that has them (the old prod) this is a no-op.
#   bi_owner    — NOLOGIN owner of the `bi` schema and its 12 views (Superset's RLS-gated surface; staging: NOINHERIT).
#   superset_ro — Superset's login to the analytics DB (staging: LOGIN NOINHERIT, no settings). LOGIN WITHOUT a password
#                 until the go-live sets one (runbook go-live-bispharma.md §4).
CLEAN_SERVER_ROLES = {
    'bi_owner':    'NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT',
    'superset_ro': 'LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION NOINHERIT',
}
# every role staging's schema grants to / owns with must exist on the target after `roles`, or the build stops here
_referenced = set(re.findall(r'^(?:GRANT|REVOKE)\b.*?\b(?:TO|FROM) ([^;]+);', pre_sql + views_sql, flags=re.M))
_referenced = {r.strip().replace(' WITH GRANT OPTION', '') for x in _referenced for r in x.split(',')}
_referenced |= set(re.findall(r'OWNER TO ([\w"@.]+);', pre_sql + views_sql))
_missing = sorted(r.strip('"') for r in _referenced if r != 'PUBLIC' and r.strip('"') not in set(P['roles']) | set(ROLES) | set(CLEAN_SERVER_ROLES))
assert not _missing, f'staging grants/owners reference roles the target lacks and `roles` does not create: {_missing}'
rl = ["\\set ON_ERROR_STOP 1", "BEGIN;", "SET LOCAL lock_timeout = '5s';"]
for r, attrs in CLEAN_SERVER_ROLES.items():   # create-if-missing only: never touch an existing role's shape
    rl.append(f"DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{r}') THEN CREATE ROLE {r} {attrs}; END IF; END $r$;")
for r, (attrs, limit, settings) in ROLES.items():
    rl.append(f"DO $r$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{r}') THEN CREATE ROLE {r} NOLOGIN; END IF; END $r$;")
    rl.append(f"ALTER ROLE {r} {attrs} CONNECTION LIMIT {limit};")
    for k in ('app.tenant_id', 'default_transaction_read_only', 'statement_timeout'):
        rl.append(f"ALTER ROLE {r} SET {k} = '{settings[k]}';" if k in settings else f"ALTER ROLE {r} RESET {k};")
rl += ["COMMIT;",
       "SELECT 'role', r.rolname, r.rolcanlogin AS login, r.rolpassword IS NULL AS no_password, r.rolbypassrls AS bypassrls, r.rolinherit,",
       "       r.rolconnlimit, coalesce(array_to_string(s.setconfig, ';'), '') AS settings",
       "  FROM pg_authid r LEFT JOIN pg_db_role_setting s ON s.setrole = r.oid AND s.setdatabase = 0",
       f" WHERE r.rolname IN ({', '.join(repr(r) for r in list(ROLES) + list(CLEAN_SERVER_ROLES))}) ORDER BY 2;"]
write('00-roles.sql', '\n'.join(rl) + '\n')
if STAGING_TS:
    write('00-joblog.sql', "\\set ON_ERROR_STOP 1\n"
          "ALTER SYSTEM SET timescaledb.enable_job_execution_logging = 'on';\nSELECT pg_reload_conf();\n"
          "SELECT pg_sleep(1);\nSELECT 'job_logging', current_setting('timescaledb.enable_job_execution_logging');\n")
else:   # no TimescaleDB jobs to log: the server setting is left alone (the old DB keeps whatever it had)
    write('00-joblog.sql', "SELECT 'job_logging', 'skipped: staging has no timescaledb (ADR-0063)';\n")
# xplant.sh `create`: the extensions the target database needs BEFORE pre.sql (pre.sql carries the others from the dump)
write('01-extensions.sql', ("CREATE EXTENSION IF NOT EXISTS timescaledb;\n" if STAGING_TS else "") +
      "SELECT 'extensions', string_agg(extname || ' ' || extversion, ', ' ORDER BY extname) FROM pg_extension;\n")

# ── 2. hypertables + caggs WITH NO DATA (dependency order). Rehearsal: create_hypertable's default index collided with
#       staging's own → create_default_indexes => false.
# HISTORY_CHUNK (2026-10-14 rehearsal, the 2nd OOM trap): prod's silver.equipment_events holds DAILY data since 2021, so
# staging's 1-day chunk interval gives 1,555 chunks (staging: 156). stream-engine's hour exclusions query
# (rollup/availability_exclusions.go: correlated subqueries on equipment_events bounded by per-row ranges) then scans every
# compressed chunk per outer row → one backend grew to 7.7 GB and the kernel OOM-killed Postgres every 1–3 min (crash loop).
# The history is created with a coarse interval; set_chunk_time_interval() restores staging's for NEW chunks (phase post).
HISTORY_CHUNK = {'silver.equipment_events': '30 days'}
out = ["\\set ON_ERROR_STOP 1"]
for t in sorted(HYPERTABLES, key=lambda t: (t['s'], t['n'])):
    _ci = HISTORY_CHUNK.get(f"{t['s']}.{t['n']}", t['ht']['chunk'])
    out.append(f"SELECT create_hypertable('{t['s']}.{t['n']}', '{t['ht']['tcol']}', chunk_time_interval => INTERVAL '{_ci}', "
               f"if_not_exists => true, migrate_data => true, create_default_indexes => false);")
order, pending = [], dict(CAGGS)
while pending:
    for k, c in list(pending.items()):
        if all(d in order for d in CAGGS if d != k and re.search(r'\b' + d[1] + r'\b', c['def'])):
            order.append(k)
            del pending[k]
for k in order:
    c = CAGGS[k]
    out.append(f"CREATE MATERIALIZED VIEW IF NOT EXISTS {k[0]}.{k[1]} WITH (timescaledb.continuous, timescaledb.materialized_only = "
               f"{str(c['mo']).lower()}) AS\n{c['def'].rstrip().rstrip(';')}\nWITH NO DATA;")
write('02-hypertables-caggs.sql', '\n'.join(out) + '\n')

# ── 3. post-data split: hypertable keys/indexes run BEFORE the copy. Rehearsal: adding the PK to a loaded hypertable built
#       every chunk's index in one transaction → 13 GB backend → kernel OOM-kill on the prod-sized box (r7g.large).
#       Also pg_dump writes ALTER TABLE ONLY, which Timescale rejects on hypertables.
post_sql = strip_personal(open(os.path.join(OUT, 'post.raw.sql'), newline='').read())
blocks = re.split(r'(?=^--\n-- Name: )', post_sql, flags=re.M)
hyper, rest = [], []
for b in blocks[1:]:
    m = re.search(r'^(?:ALTER TABLE(?: ONLY)?|CREATE (?:UNIQUE )?INDEX \S+ ON(?: ONLY)?)\s+([\w.]+)', b, re.M)
    tgt = m.group(1) if m else ''
    if '.' in tgt and staging_only(*tgt.split('.', 1)):
        continue
    if tgt in HT_NAMES:
        b = re.sub(r'ALTER TABLE ONLY ' + re.escape(tgt) + r'\b', 'ALTER TABLE ' + tgt, b)
    (hyper if tgt in HT_NAMES and 'FOREIGN KEY' not in b else rest).append(b)
write('03-hyper-keys.sql', blocks[0] + ''.join(hyper))
_restore = ''.join(f"SELECT public.set_chunk_time_interval('{t['s']}.{t['n']}'::regclass, INTERVAL '{t['ht']['chunk']}');\n"
                   for t in HYPERTABLES if f"{t['s']}.{t['n']}" in HISTORY_CHUNK)
if HYPERTABLES:
    _restore += ("SELECT 'chunks', hypertable_schema || '.' || hypertable_name, num_chunks FROM timescaledb_information.hypertables "
                 "ORDER BY 3 DESC;   -- review: > ~300 chunks on a table queried with per-row time bounds = the OOM trap above\n")
if PARTITIONED:   # native partitions: count per parent (= staging's at dump time; partition_maintain adds ahead in `policies`)
    _restore += ("SELECT 'partitions', inhparent::regclass, count(*) FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid "
                 "WHERE c.relkind = 'r' AND inhparent IN (" + ', '.join(f"'{t['s']}.{t['n']}'::regclass" for t in PARTITIONED) +
                 ") GROUP BY 2 ORDER BY 2;\n")
write('post.sql', blocks[0] + ''.join(rest) + _restore)

# ── 4. data copy from the old DB via postgres_fdw. CHECKs dropped first (re-added NOT VALID + VALIDATE after repairs).
#       production_orders does ADR-0062 P1 inline (text backfill, D5 by business key, po_uuid from ts_creation).
# `or []`: a CLEAN target server (Bispharma go-live) has no tables — 04-data-copy is then unused (the tenant load replaces it)
pt = {t['n']: t for t in (P['tables'] or []) if t['s'] == 'public'}
# a partition's CHECKs are inherited from its parent (dropping one on a partition fails: "cannot drop inherited constraint")
checks = [c for c in S['constraints'] if c['type'] == 'c' and not staging_only(c['s'], c['tbl']) and (c['s'], c['tbl']) not in PARTITIONS]
out = ["\\set ON_ERROR_STOP 0", "CREATE EXTENSION IF NOT EXISTS postgres_fdw;", "DROP SERVER IF EXISTS old_db CASCADE;",
       "CREATE SERVER old_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname 'packiot', fetch_size '50000');",
       "CREATE USER MAPPING FOR CURRENT_USER SERVER old_db;",
       "DROP SCHEMA IF EXISTS old_public CASCADE; CREATE SCHEMA old_public;",
       "IMPORT FOREIGN SCHEMA public FROM SERVER old_db INTO old_public;"]
out += [f'ALTER TABLE {c["s"]}."{c["tbl"]}" DROP CONSTRAINT IF EXISTS "{c["n"]}";' for c in checks]
out.append("SET session_replication_role = replica;")
report = {'new_no_source': [], 'not_null_no_default_no_source': [], 'type_change': [], 'prod_column_dropped': []}
for t in sorted(S['tables'], key=lambda t: (0 if t.get('ht') else 1, t['s'], t['n'])):
    if staging_only(t['s'], t['n']) or t.get('parent'):   # partitions are filled through their parent
        continue
    src = pt.get(TABLE_RENAMES.get(t['n'], t['n']))
    if not src:
        report['new_no_source'].append(f"{t['s']}.{t['n']}")
        continue
    scols = {c['n']: c for c in src['cols']}
    tcols = [c for c in t['cols'] if c.get('gen') != 's']
    renames = COLUMN_RENAMES.get((t['s'], t['n']), [])
    use = [c for c in tcols if c['n'] in scols]
    cols = [f'"{c["n"]}"' for c in use]
    sel = [f'"{c["n"]}"::{c["t"]}' for c in use]
    for new, old in renames:
        typ = next(c['t'] for c in tcols if c['n'] == new)
        cols.append(f'"{new}"')
        sel.append(f'"{old}"::{typ}')
    if (t['s'], t['n']) == ('core', 'production_orders'):
        i = cols.index('"id_order_text"')
        sel[i] = ("(CASE WHEN \"id_order\" = 889583 AND btrim(\"id_order_text\") = '889185' THEN '889583' "
                  "ELSE coalesce(nullif(btrim(\"id_order_text\"), ''), \"id_order\"::text) END)::character varying(255)")
        cols.append('"po_uuid"')
        sel.append('core.uuidv7("ts_creation")')
    for c in tcols:
        if c['n'] not in scols and c['n'] not in {n for n, _ in renames} and c['n'] != 'po_uuid':
            if c['nn'] and not c['def'] and not c['id']:
                report['not_null_no_default_no_source'].append(f"{t['s']}.{t['n']}.{c['n']}")
        elif c['n'] in scols and scols[c['n']]['t'] != c['t']:
            report['type_change'].append(f"{t['s']}.{t['n']}.{c['n']}: {scols[c['n']]['t']} -> {c['t']}")
    for c in src['cols']:
        if c['n'] not in {x['n'] for x in tcols} and c['n'] not in {o for _, o in renames}:
            report['prod_column_dropped'].append(f"{src['n']}.{c['n']}")
    ov = 'OVERRIDING SYSTEM VALUE ' if any(c['id'] for c in use) else ''
    out.append(f"\\echo copy {t['s']}.{t['n']} <- public.{src['n']}")
    out.append(f'INSERT INTO {t["s"]}."{t["n"]}" ({", ".join(cols)}) {ov}SELECT {", ".join(sel)} FROM old_public."{src["n"]}";')
out.append("SET session_replication_role = origin;")
out.append("""DO $s$ DECLARE r record; m bigint; BEGIN
  FOR r IN SELECT s.oid::regclass AS seq, d.refobjid::regclass AS tbl, a.attname AS col FROM pg_class s
             JOIN pg_depend d ON d.objid = s.oid AND d.deptype IN ('a','i')
             JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
            WHERE s.relkind = 'S' AND s.relnamespace::regnamespace::text !~ '^(_timescaledb|timescaledb)' LOOP
    EXECUTE format('SELECT max(%I) FROM %s', r.col, r.tbl) INTO m;
    IF m IS NOT NULL THEN PERFORM setval(r.seq, m); END IF;
  END LOOP; END $s$;""")
out.append("DROP SCHEMA old_public CASCADE; DROP SERVER old_db CASCADE;")
write('04-data-copy.sql', '\n'.join(out) + '\n')
json.dump(report, open(os.path.join(OUT, 'copy-report.json'), 'w'), indent=1)

# ── 5. repairs staging applied before adding constraints its schema now carries (keyed by data, idempotent)
shutil.copy(os.path.join(HERE, '05-repairs.sql'), os.path.join(OUT, '05-repairs.sql'))

# ── 6. CHECKs back: NOT VALID, then VALIDATE (a failure names the violated invariant)
out = ["\\set ON_ERROR_STOP 0"]
for c in checks:
    out.append(f'ALTER TABLE {c["s"]}."{c["tbl"]}" ADD CONSTRAINT "{c["n"]}" {c["def"]} NOT VALID;')
    out.append(f'ALTER TABLE {c["s"]}."{c["tbl"]}" VALIDATE CONSTRAINT "{c["n"]}";')
write('06-checks.sql', '\n'.join(out) + '\n')

# ── 7. data migrations (business-keyed, idempotent). printf, never echo: zsh's echo turns "\e" into ESC.
PHASE_D = ['t-backfill-equipment-config-defaults/01-backfill.sql', 't-backfill-cd-equipment/01-backfill.sql',
           't-line-lead-net-machine/01-up.sql', 't-cpack-net-machine-meter-lines/01-up.sql', 't-line-lead-counter-roles/01-up.sql',
           't-line-meter-fill/01-up.sql', 't-line-downtime-from-lead-machine/01-up.sql', 't-ideal-speed-best-demonstrated/01-set.sql',
           't-backfill-production-targets-default/01-backfill.sql',
           't-plc-link-minutes-retention/01-up.sql',  # before t-retention-catalog: PROD_RAW_RETENTION=off then nulls its keep too
           't-retention-catalog/01-up.sql',
           't-i18n-ptbr-missing-desktop-keys/01-up.sql', 't-i18n-availability-states/01-up.sql', 't-device-bindings/01-up.sql',
           't-descriptor-device-keys/01-up.sql', 't-adr0061-p3d-bindings-backfill/01-up.sql', 't-adr0062-p1-po-number-expand/01-up.sql']
# PROD_RAW_RETENTION (decided 2026-10-09: "off"). Staging drops raw/1-s/1-min data after 90 days because the historian
# cold tier keeps it; PROD HAS NO COLD TIER, so dropping it there deletes history for good. t-retention-catalog ends
# with CALL ops.apply_retention(), which ADDS Timescale drop_chunks policies from its catalog — i.e. running it as-is
# in phase D would silently arm the 90-day raw drop (the rehearsal's "retention held" covered 10-policies.sql only).
#   off (default) → the catalog is seeded, then every tier='hot_raw' relation is set keep = NULL (forever) BEFORE the
#                   first apply_retention(); no raw retention policy is ever created. Compression policies are
#                   unaffected (10-policies.sql), hot_agg/business/ops tiers keep staging's production profile.
#   on            → staging's production profile verbatim (90-day raw drop). Enable ONLY when a prod cold tier
#                   (historian + daily cold copy) exists, then re-apply db/retention/profiles/production.sql.
PROD_RAW_RETENTION = os.environ.get('PROD_RAW_RETENTION', 'off').strip().lower()
assert PROD_RAW_RETENTION in ('off', 'on'), f'PROD_RAW_RETENTION must be off|on, got {PROD_RAW_RETENTION!r}'
PRUNE_CATALOG_SQL = """
-- 2026-10-14 rehearsal: t-retention-catalog seeds silver.ca_equipment_boxes_1s, which a LATER migration
-- (t-drop-ca-equipment-boxes-1s, ADR-0063 A1) dropped together with its catalog row. The transplanted schema never has it,
-- so apply_retention() aborted on it and left the hot_agg/business policies unapplied. The catalog follows the schema:
DELETE FROM ops.retention_policy WHERE to_regclass(relation) IS NULL;
-- ADR-0063: a database without timescaledb has no hypertables/caggs; their rows become 'plain' (= what ops.pc_swap
-- does on conversion). apply_retention() skips plain rows; partitioned ones are dropped by ops.partition_maintain().
UPDATE ops.retention_policy SET kind = 'plain', updated_at = now()
 WHERE kind IN ('hypertable', 'cagg') AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb');
"""
RAW_RETENTION_OFF_SQL = """
-- PROD_RAW_RETENTION=off (build.py): keep raw history forever on prod until a cold tier exists.
UPDATE ops.retention_policy
   SET keep = NULL, updated_at = now(),
       rationale = rationale || ' [prod: keep forever — PROD_RAW_RETENTION=off until a prod cold tier exists]'
 WHERE tier = 'hot_raw' AND keep IS NOT NULL;
CALL ops.apply_retention();   -- removes any raw retention policy; adds none for hot_raw
SELECT 'raw retention policies (want 0)', count(*)
  FROM ops.ts_retention_live() l JOIN ops.retention_policy p ON p.relation = l.relation WHERE p.tier = 'hot_raw';
-- native partitions: ops.partition_maintain() drops past retention_policy.keep — no raw relation may have one
SELECT 'raw partitioned relations with a keep (want 0)', count(*)
  FROM ops.pc_state s JOIN ops.retention_policy p ON p.relation = s.rel WHERE p.tier = 'hot_raw' AND p.keep IS NOT NULL;
"""
# TRANSPLANT_MODE=tenant (Bispharma go-live 2026-10-15: a CLEAN prod + ONE tenant copied from staging by
# scripts/promotion/bispharma/tenant_extract.py). The tenant's rows ARE staging's — every business backfill above already
# ran on them there, and re-running it here CHANGES curated config: the rehearsal's fingerprint diff caught
# t-ideal-speed-best-demonstrated re-deriving one Bispharma machine's production_speed (110 → 241) and, through it, its
# line's production_targets. The t244 descriptor INSERTs would add OTHER tenants' rows. So tenant mode keeps only the
# platform catalogs the tenant copy does not carry (ops.retention_policy) and drops everything else.
# TS-free staging (2026-10-16): the tenant copy now CARRIES ops.retention_policy (staging's current catalog — kinds 'plain'
# after ADR-0063 C3, cold_copy per ADR-0065) and ops.pc_state; re-seeding it from t-retention-catalog would write the
# pre-ADR-0063 kinds back. Tenant mode then only prunes and applies PROD_RAW_RETENTION to the copied catalog.
TRANSPLANT_MODE = os.environ.get('TRANSPLANT_MODE', 'prod').strip().lower()
assert TRANSPLANT_MODE in ('prod', 'tenant'), f'TRANSPLANT_MODE must be prod|tenant, got {TRANSPLANT_MODE!r}'
if TRANSPLANT_MODE == 'tenant':
    PHASE_D = [] if not STAGING_TS else [f for f in PHASE_D if f.startswith(('t-plc-link-minutes-retention/', 't-retention-catalog/'))]
parts = ["\\set ON_ERROR_STOP 0"]
if TRANSPLANT_MODE == 'tenant' and not STAGING_TS:
    parts += ["\\echo ===== retention catalog (copied from staging by the tenant load)", PRUNE_CATALOG_SQL,
              RAW_RETENTION_OFF_SQL if PROD_RAW_RETENTION == 'off' else 'CALL ops.apply_retention();']
for f in PHASE_D:
    body = subprocess.run(['git', 'show', f'origin/staging:db/migrations/{f}'], check=True, capture_output=True, text=True).stdout
    body = body.replace('\\set ON_ERROR_STOP 1', '\\set ON_ERROR_STOP 0')
    body = _strip_tooling(body)   # a GRANT to a missing tooling role inside BEGIN…COMMIT would roll the whole migration back
    if f == 't-retention-catalog/01-up.sql' and PROD_RAW_RETENTION == 'off':
        assert body.count('CALL ops.apply_retention();') == 1, 't-retention-catalog changed shape — re-check the raw-retention switch'
        body = body.replace('CALL ops.apply_retention();',
                            '-- CALL ops.apply_retention(); deferred: PROD_RAW_RETENTION=off override follows') + PRUNE_CATALOG_SQL + RAW_RETENTION_OFF_SQL
    elif f == 't-retention-catalog/01-up.sql':
        body = body.replace('CALL ops.apply_retention();', PRUNE_CATALOG_SQL + 'CALL ops.apply_retention();')
    parts += [f"\\echo ===== {f}", body]
t244 = subprocess.run(['git', 'show', 'origin/staging:db/migrations/t244-enterprise-0613-parameterize/01-expand.sql'],
                      check=True, capture_output=True, text=True).stdout
if TRANSPLANT_MODE == 'prod':   # tenant mode: the tenant's own descriptor travels with its data; no other tenant's
    parts.append("\\echo ===== t244 client descriptors (data statements only)")
    parts += re.findall(r'^INSERT INTO core\.client_descriptors.*?;\s*$', t244, flags=re.M | re.S)
write('07-data.sql', '\n'.join(parts) + '\n')
assert '\x1b' not in open(os.path.join(OUT, '07-data.sql')).read(), 'ESC byte in 07-data.sql'

# ── 7b. CPACK (ent 3) config sync — staging's curated equipment config + reason catalog (decided 2026-10-09).
#        Input <workdir>/cpack-config.json comes from `cpack-config-sync.py extract` run READ ONLY against staging on the
#        day. Emits 07b-cpack-config.sql (apply) + 07b-cpack-config-diff.sql (read-only report); xplant phases
#        `cpack-diff` / `cpack` run them after `data`, before `logic`. Identity by base packml topic + tp + name; mismatches
#        are skipped and reported, never written.
CPACK_SNAPSHOT = os.path.join(W, 'cpack-config.json')
if os.path.exists(CPACK_SNAPSHOT):
    subprocess.run([sys.executable, os.path.join(HERE, 'cpack-config-sync.py'), 'emit', CPACK_SNAPSHOT, '-o', OUT], check=True)
else:
    print(f'NOTE: {CPACK_SNAPSHOT} absent — 07b-cpack-config*.sql NOT generated (run cpack-config-sync.py extract first)')

# ── 8. canonical logic re-apply: staging's functions + views win over anything phase D redefined
fn_sql = open(os.path.join(OUT, 'fn.raw.sql'), newline='').read()
logic = re.sub(r'^CREATE (FUNCTION|PROCEDURE) ', r'CREATE OR REPLACE \1 ', fn_sql, flags=re.M)
logic += ''.join(l for l in re.split(r'(?<=\n)', re.sub(r'^CREATE VIEW ', 'CREATE OR REPLACE VIEW ', views_sql, flags=re.M))
                  if not re.match(r'^(COMMENT ON|GRANT|REVOKE|ALTER TABLE .* OWNER TO)', l))
write('08-logic.sql', logic)

# ── 90. every COMMENT/GRANT of pre-data again, now that views and caggs exist (idempotent)
# + views and caggs: their grants live in the views list / the skipped cagg TOC entries, and the caggs only exist after
#   `hyper` — the 2026-10-14 rehearsal found every cagg with NO grants (read-api as readapi_ro → permission denied).
cagg_acl_sql = strip_personal(open(os.path.join(OUT, 'cagg_acl.raw.sql'), newline='').read())
_g = re.findall(r'^(?:COMMENT ON|GRANT|REVOKE)\b.*?;\s*$', pre_sql + views_sql + cagg_acl_sql, flags=re.M | re.S)
# statements on staging-only objects excluded above (sandbox/bf/mirror tooling) would only add expected errors
_g = [g for g in _g if not re.search(r'\bops\.(?:"?_|"?bf_|"?sandbox|"?mirror_replay_cursor)', g)]
write('90-comments-grants.sql', '\n'.join(_g) + '\n')

# ── 10/11. policies (no retention policy added here; raw retention governed by PROD_RAW_RETENTION in phase D)
#          + month-windowed catch-up refresh
shutil.copy(os.path.join(HERE, '10-policies.sql' if STAGING_TS else '10-housekeeping.sql'), os.path.join(OUT, '10-policies.sql'))
months = [f'{y}-{m:02d}-01' for y in range(2021, 2028) for m in range(1, 13)]
lines = ["\\set ON_ERROR_STOP 0", "SELECT 'refresh start', now();"]
for k in order:
    for a, b in zip(months, months[1:]):
        lines.append(f"CALL refresh_continuous_aggregate('{k[0]}.{k[1]}', '{a}', '{b}');")
lines += ["SELECT serving.refresh_downtime_events_resolved(now() - interval '150 days', now());",
          "UPDATE serving.downtime_events_resolved_meta SET coverage_from = now() - interval '150 days' WHERE id = 1;",
          "SELECT 'refresh end', now(); SELECT 'downtime_events_resolved rows', count(*) FROM serving.downtime_events_resolved;"]
write('11-refresh.sql', '\n'.join(lines) + '\n')
shutil.copy(os.path.join(HERE, 'xplant.sh'), os.path.join(OUT, 'xplant.sh'))
for f in os.listdir(OUT):
    if f.endswith('.raw.sql') or f.endswith('.list'):
        os.remove(os.path.join(OUT, f))
print('built', sorted(os.listdir(OUT)))
print('copy report:', {k: len(v) for k, v in report.items()})
print('staging timescaledb:', STAGING_TS, '| hypertables', len(HYPERTABLES), 'caggs', len(CAGGS), '| partitioned', len(PARTITIONED),
      'partitions', len(PARTITIONS))
