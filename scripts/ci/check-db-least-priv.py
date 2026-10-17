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
    # not in production compose (release 2 scope); add compose.production.yml when the service is promoted
    "barcode-service": ("barcode_service", ["compose.staging.yml", "dev/compose.yml"]),
    # production uses the role since the 2026-10 promotion (packiot/production/stream-engine-db-creds,
    # services/stream-engine/README.md § Database role)
    "stream-engine": ("stream_engine", list(COMPOSE_FILES)),
    # one role, two instances on staging (CPACK ent 3 + the sandbox twin), one on production; the DEST login
    # only — the LEGACY source login (LEGACY_DB_*) is a different database and out of scope. Not in dev (no
    # legacy stand-in). The sandbox twin instance is staging-only.
    "legacy-replicator": ("legacy_replicator", ["compose.staging.yml", "compose.production.yml"]),
    "legacy-replicator-sbx": ("legacy_replicator", ["compose.staging.yml"]),
    # ADR-0064: the STAGING (destination) login; its production source login (prod_reflector_ro, SRC_SECRET_ID)
    # is another database and SELECT-only. Staging only: production mirrors nothing.
    "prod-reflector": ("prod_reflector", ["compose.staging.yml"]),
}

# service → (the env flag that would make it connect, the compose files it must appear in)
NO_DB = {
    "analytics-sync": ("SHADOW_MIRROR_ENABLED", ["compose.staging.yml", "dev/compose.yml"]),
}
DB_LOGIN_KEYS = ("DB_USER", "DB_PASSWORD", "PG_SECRET_ID", "CREDS_SOURCE")

# Exporters configured by the postgres-exporter env contract (DATA_SOURCE_*): service → (role, compose files).
# The login must be DATA_SOURCE_USER = the literal role, the password a file (DATA_SOURCE_PASS_FILE), and no
# DATA_SOURCE_NAME (a full DSN would carry the user and password inline). Staging's exporter still uses the admin
# login and is not listed (yet); production's never may (t-postgres-exporter-role).
EXPORTERS = {
    "postgres-exporter": ("postgres_exporter", ["compose.production.yml"]),
}

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

        # legacy-replicator names its analytics login DEST_DB_* (its LEGACY_DB_* login is another database)
        user_key = "DEST_DB_USER" if "DEST_DB_USER" in env else "DB_USER"
        user = env.get(user_key)
        if user is not None and user != role:
            errors.append(f"{where}: {user_key}={user!r}; must be the literal role {role!r}")

        if default_of(env.get("CREDS_SOURCE", "")) == "env":
            if user != role:
                errors.append(f"{where}: CREDS_SOURCE=env needs {user_key}={role!r}")
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

    for name, (role, required_in) in EXPORTERS.items():
        if path not in required_in:
            continue
        if name not in services:
            errors.append(f"{path}: service {name} not found (renamed? update EXPORTERS in {__file__})")
            continue
        svc = services[name]
        env = env_of(svc)
        where = f"{path}: {name}"
        if svc.get("env_file"):
            errors.append(f"{where}: env_file puts .env (admin POSTGRES_* and all secrets) into the container")
        for k, v in sorted(env.items()):
            if ADMIN_REF.search(v):
                errors.append(f"{where}: {k}={v} references the Postgres admin login; use the {role} role")
        if "DATA_SOURCE_NAME" in env:
            errors.append(f"{where}: DATA_SOURCE_NAME carries the login inline; use DATA_SOURCE_URI + "
                          f"DATA_SOURCE_USER={role} + DATA_SOURCE_PASS_FILE")
        if env.get("DATA_SOURCE_USER") != role:
            errors.append(f"{where}: DATA_SOURCE_USER={env.get('DATA_SOURCE_USER')!r}; must be the literal role {role!r}")
        if not env.get("DATA_SOURCE_PASS_FILE") or "DATA_SOURCE_PASS" in env:
            errors.append(f"{where}: the password must come from DATA_SOURCE_PASS_FILE (not DATA_SOURCE_PASS)")

if errors:
    for e in errors:
        print(f"::error::{e}")
    sys.exit(1)
print(f"db least privilege OK: {', '.join(f'{s} as {r}' for s, (r, _) in {**SERVICES, **EXPORTERS}.items())}; "
      f"no DB login: {', '.join(NO_DB)}; in {len(COMPOSE_FILES)} compose files")
