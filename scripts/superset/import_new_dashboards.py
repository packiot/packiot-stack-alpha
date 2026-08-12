#!/usr/bin/env python3
"""Import the NEW CPACK dashboards into a live Superset — WITHOUT touching OEE Overview.

Two safety layers so the error-fix agent's OEE Overview + shared-dataset fixes are
never clobbered:
  1. The bundle EXCLUDES oee_overview.yaml and the 12 OEE-Overview chart files, so
     those objects are not even present to overwrite.
  2. Import runs with overwrite=false, so the shared datasets (oee_shift/oee_hourly/
     downtimes/production_order_runtime/equipments) — which the new dashboards DO
     reference and therefore MUST be in the bundle — are kept as-is on the server.

Only the 5 new datasets + 27 new charts + 7 new dashboards get created.

Env (never hardcode): SUPERSET_BASE_URL (default http://127.0.0.1:8088),
SUPERSET_ADMIN_USER, SUPERSET_ADMIN_PASSWORD, SUPERSET_DB_RO_PASSWORD (for the
packiot_analytics connection password prompt). ASSETS_DIR = path to
configs/superset/assets. Run ON the Superset host against loopback.
"""
import io
import json
import os
import sys
import uuid
import zipfile
import urllib.request
import urllib.error

BASE = os.environ.get("SUPERSET_BASE_URL", "http://127.0.0.1:8088").rstrip("/")
USER = os.environ.get("SUPERSET_ADMIN_USER")
PASSWORD = os.environ.get("SUPERSET_ADMIN_PASSWORD")
RO_PW = os.environ.get("SUPERSET_DB_RO_PASSWORD", "")
ASSETS = os.environ.get("ASSETS_DIR", "configs/superset/assets")

# OEE-Overview objects to EXCLUDE from the bundle (never touch the error-fix agent's).
EXCLUDE_DASHBOARDS = {"oee_overview.yaml"}
OEE_CHART_UUIDS = {
    "e12a6e1c-538a-48d6-84fe-ccb5453ff431", "9232e211-3d11-42bb-bcf4-3a8f394cc7f0",
    "b6f6e3fd-cc9b-4131-8d7a-4ea89968f2f8", "c7c4ebe1-5659-4283-baaf-636d61185684",
    "e51140c4-b5da-4be7-970b-aa8ef7c742b4", "c06d7d16-8712-425d-9b5b-85186bf5eda3",
    "6ec8f55b-f906-4c8a-9bbe-d80e9d40395d", "09c153c2-0be1-43fa-9cfe-99a6514030e0",
    "7e15ed8e-3d2f-45bd-a996-14c48db7d881", "18a6435f-64d3-440c-937e-053ebaad8d4a",
    "3b95c7b5-a542-4e39-9cf6-37264ac1f62b", "bbc7f4b9-ce5a-45a4-86a3-66c2e51101df",
}


def _req(method, path, token=None, csrf=None, cookie=None, body=None, raw=None, ctype=None):
    req = urllib.request.Request(f"{BASE}{path}", method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if csrf:
        req.add_header("X-CSRFToken", csrf)
    if cookie:
        req.add_header("Cookie", cookie)
    if body is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(body).encode()
    elif raw is not None:
        req.add_header("Content-Type", ctype)
        data = raw
    else:
        data = None
    try:
        resp = urllib.request.urlopen(req, data=data)
        txt = resp.read().decode() or "{}"
        try:
            return resp.status, json.loads(txt), resp.headers
        except json.JSONDecodeError:
            return resp.status, {"_raw": txt}, resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(), e.headers


def login():
    if not USER or not PASSWORD:
        sys.exit("SUPERSET_ADMIN_USER / SUPERSET_ADMIN_PASSWORD must be set.")
    st, b, _ = _req("POST", "/api/v1/security/login",
                    body={"username": USER, "password": PASSWORD, "provider": "db", "refresh": True})
    if st != 200 or not isinstance(b, dict) or "access_token" not in b:
        sys.exit(f"login failed: {st} {b}")
    token = b["access_token"]
    st, cb, hdr = _req("GET", "/api/v1/security/csrf_token/", token=token)
    csrf = cb.get("result") if (st == 200 and isinstance(cb, dict)) else None
    cookie = hdr.get("Set-Cookie", "").split(";")[0] if hdr.get("Set-Cookie") else None
    return token, csrf, cookie


def build_zip():
    """Zip the assets tree, dropping the OEE-Overview dashboard + its 12 charts."""
    buf = io.BytesIO()
    added = {"datasets": 0, "charts": 0, "dashboards": 0, "skipped": 0}
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(ASSETS):
            for fn in files:
                if not fn.endswith((".yaml", ".yml")):
                    continue
                fp = os.path.join(root, fn)
                rel = os.path.relpath(fp, os.path.dirname(ASSETS))  # keep assets/ prefix
                if "/dashboards/" in fp and fn in EXCLUDE_DASHBOARDS:
                    added["skipped"] += 1
                    continue
                if "/charts/" in fp:
                    txt = open(fp).read()
                    if any(u in txt for u in OEE_CHART_UUIDS) and "uuid: " in txt:
                        # only skip if THIS file's own uuid is an OEE chart uuid
                        own = [l.split("uuid:")[1].strip() for l in txt.splitlines()
                               if l.startswith("uuid:")]
                        if own and own[0] in OEE_CHART_UUIDS:
                            added["skipped"] += 1
                            continue
                z.writestr(rel, open(fp).read())
                if "/datasets/" in fp:
                    added["datasets"] += 1
                elif "/charts/" in fp:
                    added["charts"] += 1
                elif "/dashboards/" in fp:
                    added["dashboards"] += 1
    print(f"bundle: {added}")
    return buf.getvalue()


def multipart(fields, files):
    boundary = f"----ss{uuid.uuid4().hex}"
    out = io.BytesIO()
    for k, v in fields.items():
        out.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    for k, (fname, data, mime) in files.items():
        out.write(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"; filename=\"{fname}\"\r\n".encode())
        out.write(f"Content-Type: {mime}\r\n\r\n".encode())
        out.write(data)
        out.write(b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    return out.getvalue(), f"multipart/form-data; boundary={boundary}"


def main():
    token, csrf, cookie = login()
    zdata = build_zip()
    passwords = json.dumps({"databases/packiot_analytics.yaml": RO_PW})
    fields = {"overwrite": "false", "passwords": passwords}
    files = {"formData": ("bundle.zip", zdata, "application/zip")}
    raw, ctype = multipart(fields, files)
    st, body, _ = _req("POST", "/api/v1/dashboard/import/",
                       token=token, csrf=csrf, cookie=cookie, raw=raw, ctype=ctype)
    print("import status:", st)
    print(json.dumps(body, indent=2) if isinstance(body, dict) else body)
    if st not in (200, 201):
        sys.exit(1)
    print("OK — new dashboards imported (overwrite=false; OEE Overview untouched).")


if __name__ == "__main__":
    main()
