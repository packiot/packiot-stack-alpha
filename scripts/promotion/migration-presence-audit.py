#!/usr/bin/env python3
"""Promotion audit: which staging migrations does PROD already have? Heuristic, calibrated on staging."""
import re, subprocess, sys, collections, json
REPO = __import__('subprocess').run(['git','rev-parse','--show-toplevel'],capture_output=True,text=True).stdout.strip()
D = sys.argv[1]

def load(path):
    cat = collections.defaultdict(dict)
    for line in open(path):
        p = line.rstrip('\n').split('\t')
        if len(p) >= 2: cat[p[0]][p[1]] = p[2] if len(p) > 2 else ''
    return cat
stg, prd = load(f'{D}/staging.tsv'), load(f'{D}/prod.tsv')

def names(cat, kind):
    """index by full key and by bare object name"""
    full, bare = set(), collections.Counter()
    for k in cat[kind]:
        base = k.split('(')[0]
        full.add(base.lower())
        bare[base.split('.')[-1].lower() if kind != 'col' else '.'.join(base.split('.')[-2:]).lower()] += 1
    return full, bare
IDX = {}
for env, cat in (('stg', stg), ('prd', prd)):
    for kind in ('rel', 'col', 'fn', 'trg', 'schema', 'role'):
        IDX[(env, kind)] = names(cat, kind)

def exists(env, kind, name):
    name = name.lower().strip('"')
    full, bare = IDX[(env, kind)]
    if kind in ('schema', 'role'): return name in full
    if kind == 'col':  # name = [schema.]table.col
        parts = name.split('.')
        return name in full if len(parts) == 3 else bare['.'.join(parts[-2:])] > 0
    if kind == 'trg':
        return any(k.endswith('.' + name) for k in full)
    return name in full if '.' in name else bare[name] > 0

IDENT = r'((?:"?[A-Za-z_][\w$]*"?\.)?"?[A-Za-z_][\w$]*"?)'
RULES = [
  (r'CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+' + IDENT + r'\s*\(', 'fn', True),
  (r'CREATE\s+(?:UNLOGGED\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?' + IDENT, 'rel', True),
  (r'CREATE\s+(?:OR\s+REPLACE\s+)?(?:MATERIALIZED\s+)?VIEW\s+(?:IF\s+NOT\s+EXISTS\s+)?' + IDENT, 'rel', True),
  (r'CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:CONCURRENTLY\s+)?(?:IF\s+NOT\s+EXISTS\s+)?' + IDENT + r'\s+ON\b', 'rel', True),
  (r'CREATE\s+SEQUENCE\s+(?:IF\s+NOT\s+EXISTS\s+)?' + IDENT, 'rel', True),
  (r'CREATE\s+SCHEMA\s+(?:IF\s+NOT\s+EXISTS\s+)?' + IDENT, 'schema', True),
  (r'CREATE\s+ROLE\s+' + IDENT, 'role', True),
  (r'CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER\s+' + IDENT, 'trg', True),
  (r'DROP\s+(?:TABLE|VIEW|MATERIALIZED\s+VIEW|INDEX|SEQUENCE)\s+(?:IF\s+EXISTS\s+)?' + IDENT, 'rel', False),
  (r'DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?' + IDENT, 'fn', False),
  (r'DROP\s+SCHEMA\s+(?:IF\s+EXISTS\s+)?' + IDENT, 'schema', False),
]
ADDCOL = re.compile(r'ALTER\s+TABLE\s+(?:IF\s+EXISTS\s+)?(?:ONLY\s+)?' + IDENT + r'\s+((?:[^;]*?))(?:;|$)', re.I | re.S)
RENAME = re.compile(r'ALTER\s+(?:TABLE|VIEW|MATERIALIZED\s+VIEW)\s+(?:IF\s+EXISTS\s+)?' + IDENT + r'\s+RENAME\s+TO\s+' + IDENT, re.I)

def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    return re.sub(r'--[^\n]*', ' ', s)

def migration_files(name):
    out = subprocess.run(['git', '-C', REPO, 'ls-tree', '-r', '--name-only', 'origin/staging', f'db/migrations/{name}'],
                         capture_output=True, text=True).stdout.split()
    keep = [f for f in out if f.endswith('.sql') and not re.search(r'(rollback|verify|probe|check|test|ROLLBACK|down)', f.split('/')[-1], re.I)]
    return keep

def expectations(name):
    exp = []
    for f in migration_files(name):
        s = strip_comments(subprocess.run(['git', '-C', REPO, 'show', f'origin/staging:{f}'], capture_output=True, text=True).stdout)
        for pat, kind, present in RULES:
            for m in re.finditer(pat, s, re.I):
                n = m.group(1)
                if n.lower().startswith(('pg_temp.', '_')) or n.lower() in ('if',): continue
                exp.append((kind, n, present))
        for m in RENAME.finditer(s):
            exp.append(('rel', m.group(2) if '.' in m.group(2) else (m.group(1).rsplit('.', 1)[0] + '.' + m.group(2) if '.' in m.group(1) else m.group(2)), True))
            exp.append(('rel', m.group(1), False))
        for m in ADDCOL.finditer(s):
            for c in re.finditer(r'ADD\s+COLUMN\s+(?:IF\s+NOT\s+EXISTS\s+)?"?([A-Za-z_]\w*)"?', m.group(2), re.I):
                exp.append(('col', m.group(1) + '.' + c.group(1), True))
    # de-dup keeping last intent per object
    last = {}
    for k, n, p in exp: last[(k, n.lower())] = p
    return [(k, n, p) for (k, n), p in last.items()]

res, rows = {}, []
for name in [l.strip() for l in open(f'{D}/newmig.txt') if l.strip()]:
    exp = expectations(name)
    cal = [(k, n, p) for k, n, p in exp if exists('stg', k, n) == p]
    held = [(k, n, p) for k, n, p in cal if exists('prd', k, n) == p]
    if not cal: st = 'unknown'
    elif len(held) == len(cal): st = 'applied'
    elif not held: st = 'missing'
    else: st = 'partial'
    res[name] = dict(status=st, extracted=len(exp), calibrated=len(cal), held=len(held),
                     missing_on_prod=[f'{k}:{n}{"" if p else " (should be gone)"}' for k, n, p in cal if exists('prd', k, n) != p][:6])
json.dump(res, open(f'{D}/audit.json', 'w'), indent=1)
c = collections.Counter(v['status'] for v in res.values())
tot_e = sum(v['extracted'] for v in res.values()); tot_c = sum(v['calibrated'] for v in res.values())
print(dict(c), f'calibration kept {tot_c}/{tot_e} expectations ({100*tot_c/max(tot_e,1):.0f}%)')
