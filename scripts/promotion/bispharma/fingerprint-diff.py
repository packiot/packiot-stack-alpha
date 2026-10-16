#!/usr/bin/env python3
"""fingerprint-diff.py <staging extract.out> <target 12t-tenant-verify.sql.out> — exit 1 on any difference.

Both files carry `fp|<table>|<count>|…|<md5>` lines from scripts/promotion/bispharma/tenant_extract.py (the same SQL, the
same filters). Equal = every carried table has the same rows on the target as in the staging snapshot (config tables:
md5 of the ordered rows; hypertables: count, first/last day, md5 of the per-day counts)."""
import sys
def fp(path):
    out = {}
    for line in open(path, errors='replace'):
        p = line.strip().split('|')
        if p and p[0] == 'fp' and len(p) >= 4:
            out[p[1]] = p[2:]
    return out
a, b = fp(sys.argv[1]), fp(sys.argv[2])
bad = 0
# tenant purity lines from the target's verify: `purity|<table>|<rows of any other tenant>` must all be 0
for line in open(sys.argv[2], errors='replace'):
    p = line.strip().split('|')
    if p[0] == 'purity' and len(p) >= 3 and p[2] != '0':
        bad += 1
        print(f"FOREIGN ROWS {p[1]}: {p[2]} rows of another tenant on the target")
for t in sorted(set(a) | set(b)):
    if a.get(t) != b.get(t):
        bad += 1
        print(f"DIFF {t}: staging={a.get(t)} target={b.get(t)}")
rows = sum(int(v[0]) for v in a.values() if v and v[0].isdigit())
print(f"{len(a)} staging / {len(b)} target fingerprints, {rows} staging rows, {bad} different")
sys.exit(1 if bad or not a else 0)
