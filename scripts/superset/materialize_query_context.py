#!/usr/bin/env python3
"""Materialize chart query_context on a live Superset (the P1 embed-guard fix).

WHY: the embedded chart-data endpoint (guest-token @protect path) 403s any chart
whose stored `query_context` is null or points at a stale datasource id. Codified
chart assets ship query_context UUID-form with a placeholder numeric id; after import
Superset assigns each dataset a real numeric id. This script walks the charts, resolves
each one's dataset id from its UUID, and rewrites query_context (+ params datasource)
with the correct numeric id so nothing 403s in embed.

SAFE-BY-DEFAULT / COORDINATION: by default it ONLY touches charts whose query_context
is null OR whose query_context.datasource.id is 0/None (the placeholder we ship) —
i.e. NEWLY imported charts. Charts already materialized by someone else (e.g. the
OEE Overview set) are LEFT UNTOUCHED. Pass --chart-uuids a,b,c to restrict to an
explicit allowlist.

Creds/host from env (never hardcode): SUPERSET_BASE_URL (default http://127.0.0.1:8088),
SUPERSET_ADMIN_USER, SUPERSET_ADMIN_PASSWORD. Run ON the Superset host (SSM) against
the loopback so no origin-lock/CloudFront hop is needed.

    SUPERSET_ADMIN_USER=... SUPERSET_ADMIN_PASSWORD=... \
      python3 materialize_query_context.py               # only placeholder charts
    ... python3 materialize_query_context.py --dry-run    # show what it would do
"""
import argparse
import json
import os
import sys
import urllib.request
import urllib.error
import urllib.parse

BASE = os.environ.get("SUPERSET_BASE_URL", "http://127.0.0.1:8088").rstrip("/")
USER = os.environ.get("SUPERSET_ADMIN_USER")
PASSWORD = os.environ.get("SUPERSET_ADMIN_PASSWORD")


def _build_query(fd):
    """Build a query_context `queries[0]` from a chart's form_data, robust across
    viz types (big_number_total uses singular `metric`; raw tables use `all_columns`;
    aggregate uses `groupby`/pivot rows+cols; time-series prepend an x_axis BASE_AXIS).
    Trusting the asset's stored queries is unsafe — it can be empty -> 'Empty query?'."""
    metrics = list(fd.get("metrics") or [])
    if not metrics and fd.get("metric"):
        metrics = [fd["metric"]]
    q = {
        "filters": [], "extras": {"having": "", "where": ""}, "applied_time_extras": {},
        "annotation_layers": [], "row_limit": fd.get("row_limit", 10000),
        "series_limit": fd.get("series_limit", 0), "order_desc": fd.get("order_desc", True),
        "url_params": {}, "custom_params": {}, "custom_form_data": {},
    }
    tr = fd.get("time_range")
    if tr:
        q["time_range"] = tr
    x_axis = fd.get("x_axis")
    is_raw = fd.get("query_mode") == "raw" or (fd.get("all_columns") and not metrics)
    if is_raw:  # raw table: emit columns, no metrics
        q["columns"] = list(fd.get("all_columns") or [])
        q["orderby"] = []
    else:
        cols = []
        if x_axis:
            tg = fd.get("time_grain_sqla")
            q["extras"]["time_grain_sqla"] = tg
            cols.append({"timeGrain": tg, "columnType": "BASE_AXIS",
                         "sqlExpression": x_axis, "label": x_axis, "expressionType": "SQL"})
        cols += list(fd.get("groupby") or [])
        cols += list(fd.get("groupbyRows") or [])
        cols += list(fd.get("groupbyColumns") or [])
        if not cols:
            cols += list(fd.get("columns") or [])
        q["columns"] = cols
        q["metrics"] = metrics
    return q


def _req(method, path, token=None, csrf=None, cookie=None, body=None):
    url = f"{BASE}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if csrf:
        req.add_header("X-CSRFToken", csrf)
    if cookie:
        req.add_header("Cookie", cookie)
    try:
        resp = urllib.request.urlopen(req)
        raw = resp.read().decode() or "{}"
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = {"_raw": raw}
        return resp.status, parsed, resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers


def login():
    if not USER or not PASSWORD:
        sys.exit("SUPERSET_ADMIN_USER / SUPERSET_ADMIN_PASSWORD must be set (never hardcode).")
    st, body, _ = _req("POST", "/api/v1/security/login",
                       body={"username": USER, "password": PASSWORD,
                             "provider": "db", "refresh": True})
    if st != 200 or not isinstance(body, dict) or "access_token" not in body:
        sys.exit(f"login failed: {st} {body}")
    token = body["access_token"]
    st, cbody, hdr = _req("GET", "/api/v1/security/csrf_token/", token=token)
    csrf = cbody.get("result") if (st == 200 and isinstance(cbody, dict)) else None
    cookie = hdr.get("Set-Cookie", "").split(";")[0] if hdr.get("Set-Cookie") else None
    return token, csrf, cookie


def dataset_id_by_uuid(token):
    """Map dataset uuid -> numeric id (page through /api/v1/dataset)."""
    out, page = {}, 0
    while True:
        q = json.dumps({"columns": ["id", "uuid"], "page": page, "page_size": 100})
        st, body, _ = _req("GET", f"/api/v1/dataset/?q={urllib.parse.quote(q)}", token=token)
        if st != 200 or not isinstance(body, dict):
            sys.exit(f"dataset list failed: {st} {body}")
        rows = body.get("result", [])
        if not rows:
            break
        for r in rows:
            out[str(r.get("uuid"))] = r["id"]
        page += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chart-uuids", default="", help="comma-separated allowlist")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="re-materialize even charts whose qc already has a real id")
    ap.add_argument("--min-id", type=int, default=0,
                    help="only touch charts with id >= this (excludes lower-id OEE Overview charts)")
    args = ap.parse_args()
    allow = {u.strip() for u in args.chart_uuids.split(",") if u.strip()}

    token, csrf, cookie = login()
    ds_by_uuid = dataset_id_by_uuid(token)

    page, changed = 0, 0
    while True:
        q = json.dumps({"page": page, "page_size": 100})
        st, body, _ = _req("GET", f"/api/v1/chart/?q={urllib.parse.quote(q)}", token=token)
        if st != 200 or not isinstance(body, dict):
            sys.exit(f"chart list failed: {st} {body}")
        rows = body.get("result", [])
        if not rows:
            break
        for ch in rows:
            cid, cuuid = ch["id"], str(ch.get("uuid"))
            if allow and cuuid not in allow:
                continue
            if args.min_id and cid < args.min_id:
                continue
            # Read full chart to get params + query_context.
            st, full, _ = _req("GET", f"/api/v1/chart/{cid}", token=token)
            if st != 200 or not isinstance(full, dict) or "result" not in full:
                continue
            res = full["result"]
            qc_raw = res.get("query_context")
            params = json.loads(res.get("params") or "{}")
            ds = params.get("datasource", "")
            # Resolve dataset numeric id. params.datasource may be either
            # "<numeric_id>__table" (Superset already rewrote it on import) or
            # "<uuid>__table" (pre-import codified form).
            head = ds.split("__")[0] if isinstance(ds, str) and "__" in ds else None
            if head and head.isdigit():
                num_id = int(head)
            elif head:
                num_id = ds_by_uuid.get(head)
            else:
                num_id = res.get("datasource_id")
            if not num_id:
                num_id = res.get("datasource_id")
            # Decide whether to touch: only null / placeholder(id 0/None) unless allowlisted.
            needs = False
            if args.force or allow:
                needs = True
            elif qc_raw:
                try:
                    qc = json.loads(qc_raw)
                    dsid = (qc.get("datasource") or {}).get("id")
                    needs = dsid in (0, None)
                except Exception:
                    needs = True
            else:
                needs = True
            if not needs:
                continue
            if not num_id:
                print(f"  SKIP chart {cid} ({cuuid}): could not resolve dataset id")
                continue
            # Rewrite params + REBUILD query_context from form_data (the asset's
            # stored queries can be empty for big_number_total/raw-table → "Empty query?").
            numeric_ds = f"{num_id}__table"
            params["datasource"] = numeric_ds
            fd = dict(params)
            fd.update({"result_format": "json", "result_type": "full"})
            qc = {
                "datasource": {"id": num_id, "type": "table"},
                "force": False,
                "queries": [_build_query(fd)],
                "form_data": fd,
                "result_format": "json",
                "result_type": "full",
            }
            # Also (re)bind the chart's datasource FK — import can leave it unset
            # even when it rewrote params.datasource to the numeric id.
            payload = {
                "params": json.dumps(params),
                "query_context": json.dumps(qc),
                "datasource_id": num_id,
                "datasource_type": "table",
            }
            print(f"chart {cid} ({cuuid}) -> dataset {num_id}"
                  + (" [dry-run]" if args.dry_run else ""))
            if not args.dry_run:
                st, out, _ = _req("PUT", f"/api/v1/chart/{cid}", token=token,
                                  csrf=csrf, cookie=cookie, body=payload)
                if st not in (200, 201):
                    print(f"  WARN update failed: {st} {out}")
                    continue
            changed += 1
        page += 1
    print(f"done: {changed} chart(s) {'would be ' if args.dry_run else ''}materialized")


if __name__ == "__main__":
    main()
