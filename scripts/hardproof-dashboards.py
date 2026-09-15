#!/usr/bin/env python3
"""Hardproof Grafana panels against a LIVE Prometheus — prove the DATA is real,
not just that the JSON renders.

Rationale (the rule this enforces): a panel that renders is worthless if its
query returns the wrong series or silently-empty data. The v1 boards accumulated
blank tiles precisely because nobody ran the queries. lint-dashboards.py checks
STRUCTURE (datasource pinned, no banned metric names); this checks BEHAVIOUR
(every PromQL target returns a non-empty vector against the running stack).

Scope: Prometheus targets only. Postgres targets use Grafana macros
($__timeFilter / $__timeGroupAlias) that only expand inside Grafana's query
engine, so they can't be run headless here — they are listed as SKIPPED and must
be proven in Grafana (or via the SSM db channel with the macro substituted, as in
scripts/adr0032-f3-fidelity-check.sh).

Transport: set PROM_URL to a reachable Prometheus (on the self-hosted runner /
app box that's http://localhost:9090; from a laptop, open an SSM tunnel first).

Usage:
  PROM_URL=http://localhost:9090 ./scripts/hardproof-dashboards.py [dir ...]
  (default dir: grafana/dashboards/audience)

An empty result is a FAILURE unless the target's expr matches an entry in
EXPECT_EMPTY — a metric that is legitimately empty-until-first-event (a CounterVec
with no series yet). Those are healthy-zero, and each one is annotated in its
panel description.
"""
import glob
import json
import os
import sys
import urllib.parse
import urllib.request

PROM_URL = os.environ.get("PROM_URL", "http://localhost:9090").rstrip("/")

# Exprs that legitimately return an EMPTY vector on a healthy stack: CounterVecs
# with no label series until the first (bad) event. Matched by substring. Keep
# this list tight and keep each one annotated "empty = healthy" in its panel.
EXPECT_EMPTY = [
    'result="error"',                       # ingest write errors — none yet
    "packml_unresolved_topic_total",        # unmapped topics — none yet
]


def prom_query(expr):
    url = PROM_URL + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=30) as r:
        d = json.load(r)
    if d.get("status") != "success":
        raise RuntimeError(d.get("error", "query failed"))
    return d["data"]["result"]


def collect_targets(path):
    d = json.load(open(path))
    out = []  # (panel_title, kind, expr_or_sql, datasource_uid)
    for p in d.get("panels", []):
        if p.get("type") in ("row", "text"):
            continue
        for t in p.get("targets", []):
            uid = (t.get("datasource") or {}).get("uid", "")
            if t.get("expr"):
                out.append((p.get("title", ""), "prom", t["expr"], uid))
            elif t.get("rawSql"):
                out.append((p.get("title", ""), "sql", t["rawSql"], uid))
    return out


def main():
    dirs = sys.argv[1:] or ["grafana/dashboards/audience"]
    files = []
    for d in dirs:
        files += sorted(glob.glob(os.path.join(d, "**", "*.json"), recursive=True))
    if not files:
        print("no dashboards found", file=sys.stderr)
        return 1

    fails, proven, skipped = [], 0, 0
    for f in files:
        print(f"\n=== {os.path.basename(f)} ===")
        for title, kind, q, _ in collect_targets(f):
            if kind == "sql":
                skipped += 1
                print(f"  ~ SKIP (sql/Grafana-macro): {title!r}")
                continue
            try:
                res = prom_query(q)
            except Exception as e:  # noqa: BLE001
                fails.append((f, title, f"query error: {e}"))
                print(f"  ✗ {title!r}: query error: {e}")
                continue
            if res:
                proven += 1
                print(f"  ✓ {title!r}  ({len(res)} series)")
            elif any(s in q for s in EXPECT_EMPTY):
                proven += 1
                print(f"  ✓ {title!r}  (empty = healthy, allowlisted)")
            else:
                fails.append((f, title, "EMPTY vector (metric has no live series)"))
                print(f"  ✗ {title!r}: EMPTY vector — phantom/blank tile")

    print(f"\n{proven} prom targets proven, {skipped} sql skipped, {len(fails)} failed.")
    if fails:
        print("\nFAILURES:", file=sys.stderr)
        for f, t, why in fails:
            print(f"  {os.path.basename(f)} :: {t} :: {why}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
