#!/usr/bin/env python3
"""check-db-least-priv.py — keep least-privilege DB services off the Postgres admin login.

The Postgres twin of check-amqp-least-priv.py. Static: no DB, no .env, no secrets.

For every service in SERVICES, in every compose file that defines it (staging, production, dev):

1. No admin credential reaches the container:
   - no `environment:` value references ${POSTGRES_USER} / ${POSTGRES_PASSWORD} (the admin login),
   - no `env_file:` — on staging/production `.env` holds the admin login (and every other secret), and
     an env_file puts all of it into the container's environment.
2. The DB login is the service's own role:
   - CREDS_SOURCE=env  → DB_USER must be exactly the role name (literal, no ${...});
   - otherwise (Secrets Manager) → PG_SECRET_ID, including the default of a ${VAR:-default}, must be set
     and must not be an admin secret (ADMIN_SECRET_IDS).
   - DB_USER, if present at all, must be the role name.
3. The service must exist in each listed compose file, so a rename cannot make the check pass vacuously.

NO_DB services run without any DB login (e.g. analytics-sync, idle): no env_file, no admin reference, no
DB_USER / DB_PASSWORD / PG_SECRET_ID / CREDS_SOURCE at all, and their enable flag pinned to "false" — so
turning one on fails here until it has its own role (and moves to SERVICES).

The role itself (grants, NOBYPASSRLS, no superuser) is proved by the migration's verify.sql and the
service's golden test; this script only guards which login the deployment hands the service.

Run from anywhere in the repo: scripts/ci/check-db-least-priv.py
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())

# compose file → extra `docker compose` args
COMPOSE_FILES = {
    "compose.staging.yml": [],
    "compose.production.yml": [],
    "dev/compose.yml": ["--env-file", str(ROOT / "dev/.env.dev")],
}

# service → (its DB role, the compose files it must appear in and is checked in)
SERVICES = {
    "operator-gateway": ("operator_gateway", list(COMPOSE_FILES)),
    "barcode-service": ("barcode_service", ["compose.staging.yml", "dev/compose.yml"]),  # not in production yet
    # production still runs the pre-split `public` layout as packiot/production/db; its role comes with the
    # production promotion (services/stream-engine/README.md § Database role)
    "stream-engine": ("stream_engine", ["compose.staging.yml", "dev/compose.yml"]),
}

# service → (the env flag that would make it connect, the compose files it must appear in)
NO_DB = {
    "analytics-sync": ("SHADOW_MIRROR_ENABLED", ["compose.staging.yml", "dev/compose.yml"]),
}
DB_LOGIN_KEYS = ("DB_USER", "DB_PASSWORD", "PG_SECRET_ID", "CREDS_SOURCE")

# Secrets Manager ids that hold the admin login (or the legacy DB's).
ADMIN_SECRET_IDS = {"packiot/staging/db", "packiot/production/db", "databaseCredentials"}
ADMIN_REF = re.compile(r"\$\{?POSTGRES_(USER|PASSWORD)\b")

errors = []


def compose(path, extra):
    out = subprocess.check_output(
        ["docker", "compose", "-f", str(ROOT / path), *extra, "config", "--no-interpolate", "--format", "json"],
        text=True, cwd=ROOT)
    return json.loads(out)["services"]


def env_of(svc):
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) if "=" in e else (e, "") for e in env)
    return {k: ("" if v is None else str(v)) for k, v in env.items()}


def default_of(value):
    """'${VAR:-a}' → 'a'; '${VAR}' → ''; plain values pass through."""
    m = re.fullmatch(r"\$\{[A-Za-z0-9_]+(?::?-([^}]*))?\}", value)
    if m:
        return m.group(1) or ""
    return value


for path, extra in COMPOSE_FILES.items():
    services = compose(path, extra)
    for name, (role, required_in) in SERVICES.items():
        if path not in required_in:
            continue
        if name not in services:
            errors.append(f"{path}: service {name} not found (renamed? update SERVICES in {__file__})")
            continue
        svc = services[name]
        env = env_of(svc)
        where = f"{path}: {name}"

        for k, v in sorted(env.items()):
            if ADMIN_REF.search(v):
                errors.append(f"{where}: {k}={v} references the Postgres admin login; use the {role} role")
        if svc.get("env_file"):
            files = [pathlib.Path(e["path"] if isinstance(e, dict) else e).name for e in svc["env_file"]]
            errors.append(f"{where}: env_file {files} puts .env (admin POSTGRES_* and all secrets) into "
                          f"the container; list the needed values under environment: instead")

        user = env.get("DB_USER")
        if user is not None and user != role:
            errors.append(f"{where}: DB_USER={user!r}; must be the literal role {role!r}")

        if default_of(env.get("CREDS_SOURCE", "")) == "env":
            if user != role:
                errors.append(f"{where}: CREDS_SOURCE=env needs DB_USER={role!r}")
        else:
            secret = default_of(env.get("PG_SECRET_ID", ""))
            if not secret:
                errors.append(f"{where}: PG_SECRET_ID (or its ${{VAR:-default}}) is empty; the code falls back to "
                              f"the admin packiot/staging/db")
            elif secret in ADMIN_SECRET_IDS:
                errors.append(f"{where}: PG_SECRET_ID={secret} is an admin secret; use the {role} secret")

    for name, (flag, required_in) in NO_DB.items():
        if name not in services:
            if path in required_in:
                errors.append(f"{path}: service {name} not found (renamed? update NO_DB in {__file__})")
            continue
        svc = services[name]
        env = env_of(svc)
        where = f"{path}: {name}"
        if svc.get("env_file"):
            errors.append(f"{where}: env_file puts .env (admin POSTGRES_* and all secrets) into a service "
                          f"that needs no DB login")
        for k, v in sorted(env.items()):
            if ADMIN_REF.search(v):
                errors.append(f"{where}: {k}={v} references the Postgres admin login")
            elif k in DB_LOGIN_KEYS:
                errors.append(f"{where}: {k} is set, but {name} runs without a DB login")
        if env.get(flag) != "false":
            errors.append(f"{where}: {flag}={env.get(flag)!r}; enabling it needs its own least-privilege DB "
                          f"role first (then move {name} from NO_DB to SERVICES)")

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)
print(f"db least privilege OK: {', '.join(f'{s} as {r}' for s, (r, _) in SERVICES.items())}; "
      f"no DB login: {', '.join(NO_DB)}; in {len(COMPOSE_FILES)} compose files")
