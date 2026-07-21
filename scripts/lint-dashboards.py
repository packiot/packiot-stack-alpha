#!/usr/bin/env python3
"""Lint the Grafana v2 dashboards so the bug classes fixed in the v2 rebuild
cannot silently return.

Enforces, for every grafana/dashboards-v2/*.json:
  1. Valid JSON + a non-empty `uid`; uids are unique across the folder.
  2. Every panel (except text/row dividers) pins an explicit datasource uid,
     and every target does too. (v1's #1 blank-tile bug was datasource: null →
     Grafana silently used the default Postgres datasource → PromQL died.)
  3. Datasource uids are in the known provisioned set — a typo'd uid is a dead
     panel just like a null one.
  4. No banned/phantom metric names (metrics queried but never emitted in code).

Exit non-zero with a precise message on any violation. Run in CI on every PR.
"""

import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DASH_DIR = os.path.join(HERE, "..", "grafana", "dashboards-v2")

# The datasource uids provisioned in grafana/provisioning/datasources/.
KNOWN_DS = {
    "packiot-prometheus",
    "packiot-loki",
    "packiot-postgres",
    "packiot-postgres-shadow",
    "packiot-tempo",
}

# Metrics that were queried by a dashboard but never registered in Go — the
# "phantom metric" class (bake_tenant_converged sat on the flip-gate board + an
# alert, 0 series, forever). Add names here as they're retired.
BANNED_METRICS = {
    "bake_tenant_converged",
}

NON_QUERY_PANELS = {"text", "row"}


def lint_file(path, seen_uids):
    errs = []
    with open(path) as f:
        raw = f.read()
    try:
        d = json.loads(raw)
    except json.JSONDecodeError as e:
        return [f"invalid JSON: {e}"]

    uid = d.get("uid")
    if not uid:
        errs.append("missing top-level `uid`")
    elif uid in seen_uids:
        errs.append(f"duplicate uid {uid!r} (also in {seen_uids[uid]})")
    else:
        seen_uids[uid] = os.path.basename(path)

    # Collect only the QUERY strings (expr / rawSql) — a banned metric in a query
    # is a bug; a mention in a panel description (e.g. "we dropped X") is fine.
    queries = []

    def collect_queries(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k in ("expr", "rawSql", "query") and isinstance(v, str):
                    queries.append(v)
                else:
                    collect_queries(v)
        elif isinstance(node, list):
            for v in node:
                collect_queries(v)

    collect_queries(d)
    for m in BANNED_METRICS:
        if any(m in q for q in queries):
            errs.append(f"query references banned/phantom metric {m!r} (never emitted)")

    # ADR-0032 Step 1: a panel may bind its datasource to a `datasource`-type
    # template variable (`"uid": "${var}"`) so the whole board can be switched
    # between F1 (packiot-postgres) and F3 (packiot-postgres-shadow) from the
    # dashboard header. That is NOT a blank/typo'd datasource — it is valid IFF
    # the board actually defines that variable as type=datasource AND its default
    # (current.value) is a known provisioned uid (so the board renders a real DS
    # on first load, not a dead ${var}). Build the map of legal such vars.
    ds_var_defaults = {}
    for v in d.get("templating", {}).get("list", []):
        if v.get("type") == "datasource":
            ds_var_defaults[v.get("name")] = (v.get("current") or {}).get("value")

    def check_ds(obj, where):
        ds = obj.get("datasource")
        if ds is None:
            errs.append(f"{where}: missing datasource (would fall back to the default)")
            return
        uid = ds.get("uid") if isinstance(ds, dict) else None
        if not uid:
            errs.append(f"{where}: datasource has no uid")
        elif uid.startswith("${") and uid.endswith("}"):
            var = uid[2:-1]
            if var not in ds_var_defaults:
                errs.append(f"{where}: datasource var {uid!r} has no matching "
                            f"type=datasource template variable")
            elif ds_var_defaults[var] not in KNOWN_DS:
                errs.append(f"{where}: datasource var {uid!r} defaults to "
                            f"{ds_var_defaults[var]!r}, not a known datasource uid")
        elif uid not in KNOWN_DS:
            errs.append(f"{where}: unknown datasource uid {uid!r}")

    for i, panel in enumerate(d.get("panels", [])):
        ptype = panel.get("type")
        label = f"panel[{i}] {panel.get('title', '')!r} ({ptype})"
        if ptype in NON_QUERY_PANELS:
            continue
        check_ds(panel, label)
        for j, tgt in enumerate(panel.get("targets", [])):
            check_ds(tgt, f"{label} target[{j}]")

    return errs


def main():
    files = sorted(glob.glob(os.path.join(DASH_DIR, "*.json")))
    if not files:
        print(f"no dashboards found in {DASH_DIR}", file=sys.stderr)
        return 1
    seen_uids = {}
    total = 0
    for path in files:
        errs = lint_file(path, seen_uids)
        name = os.path.basename(path)
        if errs:
            total += len(errs)
            print(f"✗ {name}")
            for e in errs:
                print(f"    {e}")
        else:
            print(f"✓ {name}")
    if total:
        print(f"\n{total} dashboard lint error(s). Every panel + target must pin a "
              f"known datasource uid; no phantom metrics.", file=sys.stderr)
        return 1
    print(f"\nAll {len(files)} v2 dashboards pass.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
