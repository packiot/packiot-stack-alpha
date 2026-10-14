#!/usr/bin/env python3
"""Mirror the read-api keys from Secrets Manager into the staging .env.

Called by .github/workflows/deploy-staging.yml ("Materialize read-api keys") on
EVERY deploy, so rotating a key is: update packiot/staging/app, redeploy
(docs/runbooks/rotate-readapi-keys.md).

Input : env APP_SECRET_JSON = SecretString of packiot/staging/app (never printed).
Output: rewrites the four .env lines below in place (atomic replace, mode/owner kept).
Fails (exit 1, a ::error:: naming the missing/invalid Secrets Manager key) instead of
letting compose start read-api / the operators with empty or inconsistent auth.

Usage: APP_SECRET_JSON=... materialize-readapi-keys.py /opt/packiot/.env
       materialize-readapi-keys.py --check   (validate only, no .env write)
"""
import json
import os
import re
import sys
import tempfile

# .env variable  <-  key in the packiot/staging/app secret
WANT = {
    "REFDATA_QUERY_API_KEYS": "query_api_keys",
    "OPERATOR_REFDATA_API_KEY": "operator_refdata_api_key",
    "OPERATOR_SBX_REFDATA_API_KEY": "operator_sbx_refdata_api_key",
    "OPERATOR_BISPHARMA_REFDATA_API_KEY": "operator_bispharma_refdata_api_key",
}
HEADER = "# read-api keys (rewritten every deploy by deploy-staging.yml from packiot/staging/app)"
# .env-safe opaque token: no quotes/spaces/commas/colons (the map's separators).
TOKEN = re.compile(r"^[A-Za-z0-9._~-]+$")
MIN_LEN = 32  # `openssl rand -hex 32` = 64; shorter keys are accepted with a warning


def fail(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def validate(sec):
    missing = [k for k in WANT.values() if not str(sec.get(k) or "").strip()]
    if missing:
        for k in missing:
            print(f"::error::packiot/staging/app is missing required key '{k}' "
                  "(docs/runbooks/rotate-readapi-keys.md)")
        sys.exit(1)
    vals = {env: str(sec[k]).strip() for env, k in WANT.items()}

    keymap = {}
    entries = [p.strip() for p in vals["REFDATA_QUERY_API_KEYS"].split(",") if p.strip()]
    for i, entry in enumerate(entries, 1):
        key, _, cid = entry.rpartition(":")
        if not key or not TOKEN.match(key) or not cid.isdigit():
            fail(f"query_api_keys entry #{i} is not '<key>:<enterprise id>' with key in [A-Za-z0-9._~-]")
        if key in keymap:
            fail(f"query_api_keys entry #{i} repeats an earlier key")
        keymap[key] = cid
        if len(key) < MIN_LEN:
            print(f"::warning::query_api_keys entry #{i} (enterprise {cid}) is shorter than {MIN_LEN} chars "
                  "— rotate it (docs/runbooks/rotate-readapi-keys.md)")

    for env, k in WANT.items():
        if env == "REFDATA_QUERY_API_KEYS":
            continue
        if not TOKEN.match(vals[env]):
            fail(f"{k} contains characters outside [A-Za-z0-9._~-]")
        if vals[env] not in keymap:
            fail(f"{k} is not one of the keys in query_api_keys — that operator would 401 on every read")
    return vals, keymap


def rewrite_env(path, vals):
    real = os.path.realpath(path)
    lines = open(real).read().splitlines()
    keep = [l for l in lines if l != HEADER and not any(l.startswith(e + "=") for e in WANT)]
    keep += [HEADER] + [f"{e}={vals[e]}" for e in WANT]
    st = os.stat(real)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=".env.")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(keep) + "\n")
        os.chmod(tmp, st.st_mode & 0o7777)
        try:
            os.chown(tmp, st.st_uid, st.st_gid)
        except PermissionError:
            pass
        os.replace(tmp, real)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv):
    raw = os.environ.get("APP_SECRET_JSON", "")
    if not raw:
        fail("APP_SECRET_JSON is empty — could not read packiot/staging/app")
    try:
        sec = json.loads(raw)
    except json.JSONDecodeError:
        fail("packiot/staging/app SecretString is not JSON")
    vals, keymap = validate(sec)
    resolved = {WANT[e]: keymap[vals[e]] for e in WANT if e != "REFDATA_QUERY_API_KEYS"}
    summary = f"{len(keymap)} tenant keys; operator keys -> enterprise " + ", ".join(
        f"{k}={cid}" for k, cid in resolved.items())
    if argv[1:] == ["--check"]:
        print(f"OK (check only): {summary}")
        return
    if len(argv) != 2:
        fail("usage: materialize-readapi-keys.py <path to .env> | --check")
    rewrite_env(argv[1], vals)
    print(f"read-api keys materialized into {argv[1]}: {summary}")


if __name__ == "__main__":
    main(sys.argv)
