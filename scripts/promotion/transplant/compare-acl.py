#!/usr/bin/env python3
"""compare-acl.py acl-stg.json acl-next.json — ACLs (relations, functions, schemas), RLS, policies, role settings, Timescale
jobs, retention catalog (acl.sql output). Expected (2026-10-14 rehearsal): TOTAL 0 (the owner's own entry is
ignored: a NULL ACL means the same); jobs = staging minus raw retention (PROD_RAW_RETENTION=off) and purge_analytics_plain.
Before the cagg-grant fix this reported the 6 caggs with no grants."""
import json, re, sys
S, N = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
# pg_temp_N.*: a live engine's SESSION temp tables (stream-engine #1786 keeps snapshots in temp tables) show up in
# staging's pg_class while it runs — not schema (Bispharma rehearsal 2026-10-15: 42 of them).
sto = lambda o: bool(re.search(r'(^|\.)(_bkp|ops\._|ops\.bf|ops\.sandbox|ops\.mirror_replay_cursor)', o)) or o.startswith(('hdb_catalog', 'pg_temp_', 'pg_toast_temp_'))
def acl(a):  # drop the grantor (…/postgres) and the owner's own entry (a NULL ACL = the owner's implicit privileges)
    return sorted(y for y in (re.sub(r'/[^/]+$', '', x) for x in (a or [])) if not y.startswith('postgres='))
tot = 0
for sec in ('acl', 'fnacl', 'nspacl'):
    a = {o['o']: acl(o['acl']) for o in S[sec] or [] if not sto(o['o'])}; b = {o['o']: acl(o['acl']) for o in N[sec] or [] if not sto(o['o'])}
    miss = sorted(set(a) - set(b)); diff = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    tot += len(miss) + len(diff); print(f"{sec:8s} staging={len(a)} next={len(b)} missing={len(miss)} different={len(diff)}")
    for k in miss[:8]: print('   MISSING', k)
    for k in diff[:8]: print('   DIFF', k, 'stg-only', sorted(set(a[k]) - set(b[k])), 'next-only', sorted(set(b[k]) - set(a[k])))
a = {o['o']: (o['cmd'], sorted(o['roles']), o['qual'], o['chk']) for o in S['pol']}; b = {o['o']: (o['cmd'], sorted(o['roles']), o['qual'], o['chk']) for o in N['pol']}
d = [k for k in a if a[k] != b.get(k)]; tot += len(d); print(f"policies staging={len(a)} next={len(b)} different/missing={len(d)}", d[:5])
a = {o['o']: (o['rls'], o['force']) for o in S['rls'] if not sto(o['o'])}; b = {o['o']: (o['rls'], o['force']) for o in N['rls']}
d = [k for k in a if a[k] != b.get(k)]; tot += len(d); print(f"rls      staging={len(a)} next={len(b)} different/missing={len(d)}", d[:5], 'extra', sorted(set(b)-set(a))[:5])
a = {o['r']: sorted(o['s']) for o in S['rolesettings']}; b = {o['r']: sorted(o['s']) for o in N['rolesettings']}
print('rolesettings', 'equal' if all(b.get(k) == v for k, v in a.items()) else f'DIFF stg={a} next={b}', 'next-extra', {k: v for k, v in b.items() if k not in a})
key = lambda o: (o['proc'], o['ht'])
a = {key(o): (o['every'], o['cfg']) for o in S['jobs']}; b = {key(o): (o['every'], o['cfg']) for o in N['jobs']}
print(f"jobs staging={len(a)} next={len(b)}")
for k in sorted(set(a) | set(b)):
    if a.get(k) != b.get(k): print('   JOB', k, 'stg', a.get(k), 'next', b.get(k))
a = {o['rel']: (o['tier'], o['keep']) for o in S['retention']}; b = {o['rel']: (o['tier'], o['keep']) for o in N['retention']}
print(f"retention catalog staging={len(a)} next={len(b)}")
for k in sorted(set(a) | set(b)):
    if a.get(k) != b.get(k): print('   RET', k, 'stg', a.get(k), 'next', b.get(k))
a = {o['ht']: o['on'] for o in S['compression']}; b = {o['ht']: o['on'] for o in N['compression']}
print('compression', 'equal' if a == b else f'stg={a} next={b}')
print('TOTAL acl/policy/rls missing+different =', tot)
