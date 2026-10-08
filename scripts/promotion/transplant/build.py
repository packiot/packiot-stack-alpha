#!/usr/bin/env python3
"""Promotion transplant — generate every phase file from three inputs, so promotion day re-runs on FRESH inputs.

  build.py <workdir>

<workdir> must contain:
  stg-schema.dump   pg_dump --schema-only -Fc of staging packiot_analytics (the target schema, by construction)
  cat-stg.json      scripts/promotion/transplant/catalog.sql run on staging      (READ ONLY)
  cat-prod.json     the same query run on the prod DB                            (READ ONLY)
Writes <workdir>/out/: pre.sql 02-hypertables-caggs.sql 03-hyper-keys.sql views.sql 04-data-copy.sql 05-repairs.sql
post.sql 06-checks.sql 07-data.sql 08-logic.sql 90-comments-grants.sql 10-policies.sql 11-refresh.sql (+ xplant.sh copied).

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
    """Objects that exist only for staging's own operation (backups, backfill tooling, sandbox twin, mirror, CPACK shadow)."""
    return (n.startswith('_bkp') or (s == 'ops' and (n.startswith('_') or n.startswith('bf') or n.startswith('sandbox')))
            or (s, n) in {('ops', 'mirror_replay_cursor'), ('silver', 'equipment_events_cpac_shadow')})


CAGGS = {(c['s'], c['n']): c for c in S['caggs']}
HYPERTABLES = [t for t in S['tables'] if t.get('ht') and not staging_only(t['s'], t['n'])]
HT_NAMES = {f"{t['s']}.{t['n']}" for t in HYPERTABLES}
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
pre, views, post, fns = [], [], [], []
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
    if re.match(r'^(_timescaledb|timescaledb_)', sch) or ('timescaledb' in rest and typ.startswith('EXTENSION')):
        continue
    if typ in ('SCHEMA -', 'COMMENT - SCHEMA', 'ACL - SCHEMA') and re.search(r'(_timescaledb|timescaledb_)', rest):
        continue
    if staging_only(sch, obj.strip('"')) or staging_only(sch, name.split(' ')[0].strip('"')):
        continue
    if (sch, obj) in CAGGS or (sch, name.split(' ')[0]) in CAGGS:
        continue
    if typ in POST:
        post.append(line)
    elif typ == 'VIEW' or (typ in ('COMMENT', 'ACL') and name.startswith('VIEW ')):
        views.append(line)
    else:
        pre.append(line)
        if typ in ('FUNCTION', 'PROCEDURE'):
            fns.append(line)
for n, lst in (('pre', pre), ('views', views), ('post', post), ('fn', fns)):
    open(os.path.join(OUT, f'{n}.list'), 'w').writelines(lst)
    pg_restore(f'{n}.list', f'{n}.raw.sql')
# drop grants to the personal staging account; split keeping line endings (CRLF bodies stay byte-identical)
strip_personal = lambda s: ''.join(l for l in re.split(r'(?<=\n)', s) if not re.search(r'"?dev@packiot\.com"?', l))
pre_sql = strip_personal(open(os.path.join(OUT, 'pre.raw.sql'), newline='').read())
write('pre.sql', pre_sql)
views_sql = strip_personal(open(os.path.join(OUT, 'views.raw.sql'), newline='').read())
write('views.sql', views_sql)

# ── 2. hypertables + caggs WITH NO DATA (dependency order). Rehearsal: create_hypertable's default index collided with
#       staging's own → create_default_indexes => false.
out = ["\\set ON_ERROR_STOP 1"]
for t in sorted(HYPERTABLES, key=lambda t: (t['s'], t['n'])):
    out.append(f"SELECT create_hypertable('{t['s']}.{t['n']}', '{t['ht']['tcol']}', chunk_time_interval => INTERVAL '{t['ht']['chunk']}', "
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
    if tgt in HT_NAMES:
        b = re.sub(r'ALTER TABLE ONLY ' + re.escape(tgt) + r'\b', 'ALTER TABLE ' + tgt, b)
    (hyper if tgt in HT_NAMES and 'FOREIGN KEY' not in b else rest).append(b)
write('03-hyper-keys.sql', blocks[0] + ''.join(hyper))
write('post.sql', blocks[0] + ''.join(rest))

# ── 4. data copy from the old DB via postgres_fdw. CHECKs dropped first (re-added NOT VALID + VALIDATE after repairs).
#       production_orders does ADR-0062 P1 inline (text backfill, D5 by business key, po_uuid from ts_creation).
pt = {t['n']: t for t in P['tables'] if t['s'] == 'public'}
checks = [c for c in S['constraints'] if c['type'] == 'c' and not staging_only(c['s'], c['tbl'])]
out = ["\\set ON_ERROR_STOP 0", "CREATE EXTENSION IF NOT EXISTS postgres_fdw;", "DROP SERVER IF EXISTS old_db CASCADE;",
       "CREATE SERVER old_db FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname 'packiot', fetch_size '50000');",
       "CREATE USER MAPPING FOR CURRENT_USER SERVER old_db;",
       "DROP SCHEMA IF EXISTS old_public CASCADE; CREATE SCHEMA old_public;",
       "IMPORT FOREIGN SCHEMA public FROM SERVER old_db INTO old_public;"]
out += [f'ALTER TABLE {c["s"]}."{c["tbl"]}" DROP CONSTRAINT IF EXISTS "{c["n"]}";' for c in checks]
out.append("SET session_replication_role = replica;")
report = {'new_no_source': [], 'not_null_no_default_no_source': [], 'type_change': [], 'prod_column_dropped': []}
for t in sorted(S['tables'], key=lambda t: (0 if t.get('ht') else 1, t['s'], t['n'])):
    if staging_only(t['s'], t['n']):
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
           't-backfill-production-targets-default/01-backfill.sql', 't-retention-catalog/01-up.sql',
           't-i18n-ptbr-missing-desktop-keys/01-up.sql', 't-i18n-availability-states/01-up.sql', 't-device-bindings/01-up.sql',
           't-descriptor-device-keys/01-up.sql', 't-adr0061-p3d-bindings-backfill/01-up.sql', 't-adr0062-p1-po-number-expand/01-up.sql']
parts = ["\\set ON_ERROR_STOP 0"]
for f in PHASE_D:
    body = subprocess.run(['git', 'show', f'origin/staging:db/migrations/{f}'], check=True, capture_output=True, text=True).stdout
    parts += [f"\\echo ===== {f}", body.replace('\\set ON_ERROR_STOP 1', '\\set ON_ERROR_STOP 0')]
t244 = subprocess.run(['git', 'show', 'origin/staging:db/migrations/t244-enterprise-0613-parameterize/01-expand.sql'],
                      check=True, capture_output=True, text=True).stdout
parts.append("\\echo ===== t244 client descriptors (data statements only)")
parts += re.findall(r'^INSERT INTO core\.client_descriptors.*?;\s*$', t244, flags=re.M | re.S)
write('07-data.sql', '\n'.join(parts) + '\n')
assert '\x1b' not in open(os.path.join(OUT, '07-data.sql')).read(), 'ESC byte in 07-data.sql'

# ── 8. canonical logic re-apply: staging's functions + views win over anything phase D redefined
fn_sql = open(os.path.join(OUT, 'fn.raw.sql'), newline='').read()
logic = re.sub(r'^CREATE (FUNCTION|PROCEDURE) ', r'CREATE OR REPLACE \1 ', fn_sql, flags=re.M)
logic += ''.join(l for l in re.split(r'(?<=\n)', re.sub(r'^CREATE VIEW ', 'CREATE OR REPLACE VIEW ', views_sql, flags=re.M))
                  if not re.match(r'^(COMMENT ON|GRANT|REVOKE|ALTER TABLE .* OWNER TO)', l))
write('08-logic.sql', logic)

# ── 90. every COMMENT/GRANT of pre-data again, now that views and caggs exist (idempotent)
write('90-comments-grants.sql', '\n'.join(re.findall(r'^(?:COMMENT ON|GRANT|REVOKE)\b.*?;\s*$', pre_sql, flags=re.M | re.S)) + '\n')

# ── 10/11. policies (retention HELD) + month-windowed catch-up refresh
shutil.copy(os.path.join(HERE, '10-policies.sql'), os.path.join(OUT, '10-policies.sql'))
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
