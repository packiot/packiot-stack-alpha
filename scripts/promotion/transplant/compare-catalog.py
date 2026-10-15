#!/usr/bin/env python3
"""compare-catalog.py cat-stg.json cat-next.json — diff of catalog.sql output (staging = target). Rehearsal 2026-10-14.
Expected: TOTAL 0; extras = hdb_catalog (hasura phase); views differ only by PG15→16 column qualification (md5)."""
import json, re, sys
S, N = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
def sto(s, n):
    n = (n or '').strip('"')
    return n.startswith('_bkp') or (s == 'ops' and (n.startswith('_') or n.startswith('bf') or n.startswith('sandbox'))) or (s, n) == ('ops', 'mirror_replay_cursor')
def norm(x):
    x = re.sub(r'_hyper_\d+_\d+_chunk|_materialized_hypertable_\d+', 'X', x or '')
    x = re.sub(r'\b[a-z_0-9]+\.(?=[a-z_])', '', x)   # PG15 qualifies columns with the table name, PG16 does not
    return re.sub(r'\s+', ' ', x).strip()
KEYS = {'tables': ('s', 'n'), 'indexes': ('s', 'tbl', 'n'), 'constraints': ('s', 'tbl', 'n'), 'sequences': ('s', 'n'), 'views': ('s', 'n'),
        'caggs': ('s', 'n'), 'functions': ('s', 'n', 'args'), 'types': ('s', 'n'), 'policies': ('s', 'tbl', 'n'), 'triggers': ('s', 'tbl', 'n')}
VAL = {'tables': lambda t: (t['kind'], t['rls'], t['force'], bool(t['ht']), tuple((c['n'], c['t'], c['nn'], norm(c['def']), c['id'], c['gen']) for c in sorted(t['cols'], key=lambda c: c['n']))),
       'indexes': lambda i: norm(i['def']), 'constraints': lambda c: (c['type'], norm(c['def'])), 'sequences': lambda q: q.get('owned'),
       'views': lambda v: v['md5'], 'caggs': lambda c: (c['mo'], norm(c['def'])), 'functions': lambda f: f['md5'], 'types': lambda t: 1,
       'policies': lambda p: 1, 'triggers': lambda t: norm(t['def'])}
total = 0
for sec, ks in KEYS.items():
    a = {tuple(o[k] for k in ks): o for o in (S.get(sec) or []) if not sto(o['s'], o.get('tbl') or o['n']) and not sto(o['s'], o['n'])}
    b = {tuple(o[k] for k in ks): o for o in (N.get(sec) or [])}
    miss, extra = sorted(set(a) - set(b)), sorted(set(b) - set(a))
    diff = sorted(k for k in set(a) & set(b) if VAL[sec](a[k]) != VAL[sec](b[k]))
    total += len(miss) + (len(diff) if sec != 'views' else 0)
    print(f"{sec:12s} staging={len(a):5d} next={len(b):5d} missing={len(miss)} extra={len(extra)} different={len(diff)}")
    for tag, lst in (('MISSING', miss), ('EXTRA', extra), ('DIFF', diff)):
        for k in lst[:15]:
            print(f"   {tag} {'.'.join(map(str, k))}")
print('schemas missing', sorted(set(S['schemas']) - set(N['schemas'])), 'extra', sorted(set(N['schemas']) - set(S['schemas'])))
print('TOTAL missing+different (views excluded: PG15→16 normalization) =', total)
