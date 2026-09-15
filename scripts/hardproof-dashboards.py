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
    # Activity-gated counters: on idle staging they have no series yet. Verified
    # ABSENT-because-inactive (not dead): the metric is registered, the flow just
    # hasn't run. Each is "empty = healthy" in its panel description.
    "operator_adapter_requests_total",      # no operator actions run on staging
    "po_gate_degraded_total",               # PO gate never degraded = healthy
    'route=~"/api/production-orders',       # no PO-route traffic to edge-api yet
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
            q = t.get("expr") or t.get("rawSql")
            if not q:
                continue
            # Kind is decided by the DATASOURCE, not by expr-vs-rawSql: Loki
            # (LogQL) and Tempo (TraceQL) also use `expr`, and running those
            # against Prometheus /api/v1/query would falsely fail. Only
            # prometheus targets are hardproofed here; everything else is skipped.
            if uid == "packiot-prometheus":
                out.append((p.get("title", ""), "prom", q, uid))
            else:
                out.append((p.get("title", ""), "other", q, uid))
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
        for title, kind, q, uid in collect_targets(f):
            if kind != "prom":
                skipped += 1
                why = "sql/Grafana-macro" if uid.startswith("packiot-postgres") else f"non-prom ds ({uid})"
                print(f"  ~ SKIP ({why}): {title!r}")
                continue
            # Grafana template/interval variables ($datname, $job, $__rate_interval,
            # …) only expand inside Grafana's query engine. A headless query sends
            # them literally → false EMPTY. Skip; prove these via Grafana /api/ds/query.
            if "$" in q:
                skipped += 1
                print(f"  ~ SKIP (Grafana $var — prove via /api/ds/query): {title!r}")
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
