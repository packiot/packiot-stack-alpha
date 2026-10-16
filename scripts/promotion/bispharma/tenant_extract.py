#!/usr/bin/env python3
"""Single-tenant data migration (staging → a CLEAN production DB) — generate the extract / load / verify SQL from the catalog.

  tenant_extract.py <workdir> [--enterprise 5] [--platform 1000000] [--dir /tmp/tenant5]

Why: the Bispharma go-live (docs/runbooks/go-live-bispharma.md) starts production CLEAN — schema by construction from
staging (scripts/promotion/transplant/build.py phases create/pre/hyper/views/post/checks/data/logic/grants/policies) —
and carries ONE tenant's config + history from staging, with every id PRESERVED (ids, device keys, topic routes and
api keys are referenced by the factory box, the operator SPA and the reader; renumbering would break all of them).

<workdir>/cat-stg.json = scripts/promotion/transplant/catalog.sql run READ ONLY on staging (the same input build.py uses).
Writes <workdir>/tenant/:
  extract.sql  STAGING, READ ONLY: one REPEATABLE READ READ ONLY snapshot; `\\copy (SELECT … WHERE <tenant filter>) TO`
               one file per table under --dir; then the fingerprints (row counts + md5 of the ordered rows for config
               tables, count/min/max/md5-of-daily-counts for hypertables) of exactly what was exported.
  load.sql     TARGET (packiot_next, after `views`, before `post`): drop CHECKs (06-checks re-adds + VALIDATEs them),
               session_replication_role = replica, `\\copy … FROM` each file, sequences setval to the copied max.
  verify.sql   TARGET (after `data`/`logic`): the same fingerprints. extract.out vs verify.out must be IDENTICAL
               (compare with fingerprint-diff.py) — proves nothing was lost, duplicated, or changed by the phase-D migrations.
  plan.json    table → copy|global|skip, the filter, and why.

Every staging table must have a rule: a table with no tenant key and no explicit rule STOPS the generator (a new table
added to staging must be decided, not silently dropped or copied whole).
"""
import argparse, json, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument('workdir')
ap.add_argument('--enterprise', type=int, default=5)
ap.add_argument('--platform', type=int, default=1000000, help='platform admin enterprise (enterprise row, roles, users only)')
ap.add_argument('--dir', default='/tmp/tenant5')
a = ap.parse_args()
S = json.load(open(os.path.join(a.workdir, 'cat-stg.json')))
OUT = os.path.join(a.workdir, 'tenant')
os.makedirs(OUT, exist_ok=True)
E, P, D = a.enterprise, a.platform, a.dir.rstrip('/')


def staging_only(s, n):   # == build.py staging_only(): objects that exist only for staging's own operation
    return (n.startswith('_bkp') or n.endswith('__old') or (s == 'ops' and (n.startswith('_') or n.startswith('bf') or n.startswith('sandbox')))
            or (s, n) in {('ops', 'mirror_replay_cursor')})


EQ = f'SELECT id_equipment FROM core.equipments WHERE id_enterprise = {E}'
# Copied whole: platform reference data with no tenant key (identical for every tenant).
GLOBAL = {
    'config.translations': 'i18n catalog (platform-wide)',
    'config.language_packs': 'i18n packs (platform-wide)',
    'config.pages': 'menu/page registry (platform-wide)',
    'silver.machine_state': 'state code → label lookup (5 rows)',
    'public.knex_migrations': 'edge-api knex ledger: db-knex-baseline/db-migrate must see every migration as applied',
    'public.knex_migrations_lock': 'knex lock row',
    'serving.downtime_events_resolved_meta': 'serving coverage marker (1 row; 11-refresh re-sets coverage_from)',
    # ADR-0063 C3: which tables are native-partitioned (rel, step, time column, key) — ops.partition_maintain() iterates it
    # to keep partitions ahead; without these rows prod would run out of partitions 60 days after go-live.
    'ops.pc_state': 'native-partition registry (platform-wide; partition_maintain reads it)',
}
# Copied whole but NOT fingerprinted: platform catalogs a later phase changes ON PURPOSE.
CATALOG = {
    # TS-free staging (2026-10-16): the catalog now describes partitioned/plain relations; the t-retention-catalog re-seed
    # would write the pre-ADR-0063 kinds (hypertable/cagg). Phase `data` then applies PROD_RAW_RETENTION (hot_raw keep → NULL).
    'ops.retention_policy': "staging's retention catalog; phase `data` sets hot_raw keep = NULL (PROD_RAW_RETENTION=off)",
}
# Not carried, each with the reason (a CLEAN start).
SKIP = {
    'bronze.equipment_values_raw': 'raw ingest replay buffer (90-day on staging); silver is the system of record. Prod raw starts at go-live',
    'bronze.equipment_events_raw': 'raw ingest replay buffer (empty on staging)',
    'ops.idempotency_keys': 'edge-api idempotency cache (24 h, no tenant key) — transient',
    'ops.legacy_manual_event_link': 'CPACK legacy-replicator link table (ent 3)',
    'ops.mirror_replay_dlq': 'CPACK legacy-replicator DLQ',
    'ops.retention_run': 'staging retention run log',
    'ops.data_invariant_result': "staging's invariant run history; prod's first run writes its own",
    'silver.rollup_invalidation': 'ADR-0063 B1 transient work queue of the rollup tick',
    # ADR-0065 (2026-10-16): staging's cold tier. The manifest points at STAGING's S3 bucket; on prod it would claim
    # archives prod does not have (and open partition_maintain's drop gate if a keep were ever set). Prod has no cold tier.
    'ops.cold_export': "staging cold-tier manifest (staging bucket) — prod has no cold tier",
    'ops.partition_drop_blocked': "staging's partition_maintain report (runtime state)",
}
# Large former caggs, now plain tables the rollup tick writes (ADR-0063 B2): per-day counts like the partitioned tables
# (they used to be refreshed on the target, never copied; a full-row md5 would string_agg millions of rows).
CHEAP_FP = {'silver.equipment_categorical_1min': 'ts_value', 'silver.equipment_categorical_1hour': 'ts_value',
            'silver.agg_equipment_values_1min': 'ts_value', 'silver.agg_equipment_values_1hour': 'ts_value'}
PLATFORM_TABLES = {'core.enterprises', 'identity.users', 'identity.user_roles'}
PLAN = []
for t in sorted(S['tables'], key=lambda t: (t['s'], t['n'])):
    s, n = t['s'], t['n']
    k = f'{s}.{n}'
    if staging_only(s, n) or t.get('parent'):   # a partition's rows are read/written through its parent
        continue
    cols = [c['n'] for c in t['cols'] if c.get('gen') != 's']
    # time-series tables get the cheap per-day fingerprint: hypertables (TimescaleDB) or native partitioned parents
    ht = t.get('ht') or t.get('part') or (CHEAP_FP.get(k) and {'tcol': CHEAP_FP[k]})
    if k in SKIP:
        PLAN.append({'t': k, 'mode': 'skip', 'why': SKIP[k]}); continue
    if k in GLOBAL:
        PLAN.append({'t': k, 'mode': 'global', 'where': 'true', 'why': GLOBAL[k], 'cols': cols, 'ht': ht}); continue
    if k in CATALOG:
        PLAN.append({'t': k, 'mode': 'catalog', 'where': 'true', 'why': CATALOG[k], 'cols': cols, 'ht': ht}); continue
    if 'id_enterprise' in cols:
        ents = f'{E}, {P}' if k in PLATFORM_TABLES else f'{E}'
        w, why = f'id_enterprise IN ({ents})', 'tenant key id_enterprise'
    elif 'customer_id' in cols:
        w, why = f'customer_id = {E}', 'tenant key customer_id'
    elif 'id_equipment' in cols:
        w, why = f'id_equipment IN ({EQ})', 'via core.equipments'
    elif 'id_area' in cols:
        w, why = f'id_area IN (SELECT id_area FROM core.areas WHERE id_enterprise = {E})', 'via core.areas'
    elif 'id_site' in cols:
        w, why = f'id_site IN (SELECT id_site FROM core.sites WHERE id_enterprise = {E})', 'via core.sites'
    elif 'id_production_order' in cols:
        w, why = f'id_production_order IN (SELECT id_production_order FROM core.production_orders WHERE id_enterprise = {E})', 'via core.production_orders'
    else:
        sys.exit(f'NO RULE for {k} (columns {cols}) — decide: GLOBAL, SKIP, or a tenant filter, then re-run')
    PLAN.append({'t': k, 'mode': 'copy', 'where': w, 'why': why, 'cols': cols, 'ht': ht})
json.dump(PLAN, open(os.path.join(OUT, 'plan.json'), 'w'), indent=1)

q = lambda c: '"' + c + '"'
fname = lambda k: f"{D}/{k}.copy"
sel = lambda p: f"SELECT {', '.join(q(c) for c in p['cols'])} FROM {p['t']} WHERE {p['where']}"
moved = [p for p in PLAN if p['mode'] != 'skip']


def fingerprints():
    out = ["\\pset format unaligned", "\\pset fieldsep '|'", "\\pset tuples_only on"]
    for p in moved:
        if p['mode'] == 'catalog':
            continue
        if p['ht']:   # hypertable: count + first/last day + md5 of the per-day counts (cheap on compressed chunks)
            tc = q(p['ht']['tcol'])
            out.append(f"SELECT 'fp', '{p['t']}', coalesce(sum(n), 0), min(d), max(d), "
                       f"md5(coalesce(string_agg(d::text || ':' || n, ',' ORDER BY d), '')) "
                       f"FROM (SELECT date_trunc('day', {tc}) d, count(*) n FROM {p['t']} WHERE {p['where']} GROUP BY 1) x;")
        else:
            out.append(f"SELECT 'fp', '{p['t']}', count(*), md5(coalesce(string_agg(x::text, E'\\n' ORDER BY x::text), '')) FROM ({sel(p)}) x;")
    return out


ex = ["\\set ON_ERROR_STOP 1", f"\\! mkdir -p {D}",
      "-- STAGING, READ ONLY. One snapshot for every table (consistent cut).",
      "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;", "SET LOCAL statement_timeout = '20min';",
      "SELECT 'snapshot', now(), pg_current_snapshot();"]
for p in moved:
    ex.append(f"\\echo copy {p['t']}")
    ex.append(f"\\copy ({sel(p)}) TO '{fname(p['t'])}'")
ex += fingerprints() + ["COMMIT;"]
open(os.path.join(OUT, 'extract.sql'), 'w').write('\n'.join(ex) + '\n')

PARTS = {(t['s'], t['n']) for t in S['tables'] if t.get('parent')}
# a partition's CHECKs are inherited from its parent: dropping/adding them on the parent covers it (dropping on the
# partition fails: "cannot drop inherited constraint")
checks = [c for c in S['constraints'] if c['type'] == 'c' and not staging_only(c['s'], c['tbl']) and (c['s'], c['tbl']) not in PARTS]
ld = ["\\set ON_ERROR_STOP 1", "-- TARGET packiot_next (after `views`, before `post`). CHECKs come back NOT VALID + VALIDATE in phase `checks`."]
ld += [f'ALTER TABLE {c["s"]}."{c["tbl"]}" DROP CONSTRAINT IF EXISTS "{c["n"]}";' for c in checks]
ld.append("SET session_replication_role = replica;")
for p in moved:
    ld.append(f"\\echo load {p['t']}")
    ld.append(f"\\copy {p['t']} ({', '.join(q(c) for c in p['cols'])}) FROM '{fname(p['t'])}'")
ld.append("SET session_replication_role = origin;")
ld.append("""DO $s$ DECLARE r record; m bigint; BEGIN
  FOR r IN SELECT s.oid::regclass AS seq, d.refobjid::regclass AS tbl, a.attname AS col FROM pg_class s
             JOIN pg_depend d ON d.objid = s.oid AND d.deptype IN ('a','i')
             JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
            WHERE s.relkind = 'S' AND s.relnamespace::regnamespace::text !~ '^(_timescaledb|timescaledb)' LOOP
    EXECUTE format('SELECT max(%I) FROM %s', r.col, r.tbl) INTO m;
    IF m IS NOT NULL THEN PERFORM setval(r.seq, m); END IF;
  END LOOP; END $s$;""")
open(os.path.join(OUT, 'load.sql'), 'w').write('\n'.join(ld) + '\n')
# Tenant purity (target only): no row of ANY other tenant anywhere — a clean single-tenant prod must not inherit a
# migration's or a backfill's rows for other enterprises (the rehearsal caught t244 inserting other tenants' descriptors).
purity = []
for t in sorted(S['tables'], key=lambda t: (t['s'], t['n'])):
    k = f"{t['s']}.{t['n']}"
    cols = [c['n'] for c in t['cols']]
    if staging_only(t['s'], t['n']) or k in SKIP or t.get('parent'):
        continue
    ents = f'{E}, {P}' if k in PLATFORM_TABLES else f'{E}'
    key = 'id_enterprise' if 'id_enterprise' in cols else ('customer_id' if 'customer_id' in cols else None)
    if key:
        purity.append(f"SELECT 'purity', '{k}', count(*) FROM {k} WHERE {key} IS NOT NULL AND NOT ({key} = ANY (ARRAY[{ents}]));")
open(os.path.join(OUT, 'verify.sql'), 'w').write('\n'.join(["\\set ON_ERROR_STOP 1", "BEGIN READ ONLY;"] + fingerprints() + purity + ["COMMIT;"]) + '\n')
# the xplant.sh phases `tload` / `tverify` read these names from build.py's out/ dir
os.makedirs(os.path.join(a.workdir, 'out'), exist_ok=True)
for src, dst in (('load.sql', '04t-tenant-load.sql'), ('verify.sql', '12t-tenant-verify.sql')):
    open(os.path.join(a.workdir, 'out', dst), 'w').write(open(os.path.join(OUT, src)).read())
# seq-floor.sql ships as-is (xplant.sh phase `seqfloor`, before the swap)
open(os.path.join(a.workdir, 'out', 'seq-floor.sql'), 'w').write(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'seq-floor.sql')).read())
print(f"tables: copy {sum(p['mode']=='copy' for p in PLAN)}, global {sum(p['mode']=='global' for p in PLAN)}, catalog {sum(p['mode']=='catalog' for p in PLAN)}, skip {sum(p['mode']=='skip' for p in PLAN)}; "
      f"checks dropped/re-added {len(checks)}; out {OUT}")
