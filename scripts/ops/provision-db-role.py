#!/usr/bin/env python3
"""Provision (or rotate) a service's least-privilege DB login on the HOST — the password never leaves it.

One script for every service in ROLES below (each has a db/migrations/t-<service>-role/ migration and a
"Provisioning the DB role" runbook in its README). Run on the stack's app host as root, AFTER the
service's 01-up.sql is applied:

  1. checks the role exists and is LOGIN, NOSUPERUSER, NOBYPASSRLS (else: apply the migration first);
  2. Secrets Manager packiot/<env>/<service>-db-creds: reuses the password if the secret exists, otherwise
     generates one (256-bit, hex) and creates the secret {host, port, user, password, name} — the shape
     every Go service's secrets loader reads. --rotate always generates a new one;
  3. sets the role's password as a SCRAM-SHA-256 verifier computed here, so the plaintext is never sent
     to Postgres (nothing to leak into the server log or pg_stat_statements); log_statement is off too;
  4. logs in AS the role with the secret's password, through the secret's host (the same path the
     service takes, e.g. pgbouncer), and checks current_user + the role's session defaults.

Steps 1 and 3 run as the admin against --admin-host (the DB host directly: a session SET does not
survive pgbouncer transaction pooling). Prints ids, fingerprints and results, never a password. Admin
login: POSTGRES_USER/POSTGRES_PASSWORD from the .env (read line by line, never sourced). psql runs in
postgres:15-alpine on the stack network.

  provision-db-role.py --service barcode-service                 # staging: create-or-reuse, set, verify
  provision-db-role.py --service barcode-service --check         # verify only (steps 1 + 4)
  provision-db-role.py --service barcode-service --rotate        # new password; then recreate the service
  provision-db-role.py --service barcode-service --env production --db-host <h> --admin-host <h>
  (services: operator-gateway, barcode-service, stream-engine, legacy-replicator, sparkplug-agent, prod-reflector,
   prod-reflector-ro, readapi-ro)
  provision-db-role.py --service readapi-ro --env production --db-name packiot \
      --db-host 10.20.10.89 --admin-host 10.20.10.89   # go-live step 8: APPLIES terraform's password, never creates one
  provision-db-role.py --service prod-reflector-ro --env production --db-name packiot \
      --db-host 10.20.10.89 --admin-host 10.20.10.89   # ADR-0064, on the PRODUCTION app host; the staging
      # reflector reads the resulting secret packiot/production/prod-reflector-ro-db-creds over the VPC peering
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import tempfile

PSQL_IMAGE = "postgres:15-alpine"
STAGING_DB_HOST = "10.10.10.89"

# service → its role, the host its secret points at on staging (the path the service connects through),
# and the session defaults its migration sets (checked in step 4 as the role).
ROLES = {
    "operator-gateway": {
        "role": "operator_gateway",
        "staging_host": STAGING_DB_HOST,
        "settings": {"default_transaction_read_only": "on", "statement_timeout": "5s"},
    },
    "barcode-service": {
        "role": "barcode_service",
        "staging_host": "pgbouncer",   # unchanged path; pgbouncer auth_query + SCRAM pass-through (as readapi_ro)
        "settings": {"statement_timeout": "30s"},
    },
    "stream-engine": {
        "role": "stream_engine",
        "staging_host": STAGING_DB_HOST,   # direct: session advisory locks + SET (see compose.staging.yml)
        "settings": {"app.tenant_id": "-1"},   # cross-tenant engine: the all-tenant RLS sentinel
    },
    "legacy-replicator": {                 # DEST login of legacy-replicator AND legacy-replicator-sbx
        "role": "legacy_replicator",
        "staging_host": STAGING_DB_HOST,   # direct: pgbouncer's static db list excludes packiot_analytics
        "settings": {},   # no tenant default: each instance stamps app.tenant_id=DST_ENTERPRISE at connect
    },
    "sparkplug-agent": {                   # shared sparkplug-agent: PLC link health + saved derive rules
        "role": "sparkplug_agent",
        "staging_host": STAGING_DB_HOST,   # direct, like stream-engine (pgbouncer's db list excludes packiot_analytics)
        "settings": {"app.tenant_id": "-1", "statement_timeout": "30s"},   # multi-tenant writer (t-sparkplug-agent-role)
    },
    # ADR-0064 prod-reflector. Two logins in two databases (db/migrations/t-prod-reflector-roles):
    "prod-reflector": {                    # STAGING destination; run on the staging app host
        "role": "prod_reflector",
        "migration": "t-prod-reflector-roles",
        "staging_host": STAGING_DB_HOST,   # direct (pgbouncer's static db list excludes packiot_analytics)
        "settings": {},   # no tenant default: the reflector stamps app.tenant_id=<mirrored enterprise> at connect
    },
    # PRODUCTION source; run on the PRODUCTION app host with --env production --db-name packiot
    # --db-host/--admin-host <prod DB private IP>. Never provisioned on staging (that role has no password).
    "prod-reflector-ro": {
        "role": "prod_reflector_ro",
        "migration": "t-prod-reflector-roles",
        "staging_host": STAGING_DB_HOST,
        "settings": {"default_transaction_read_only": "on", "statement_timeout": "120s"},
    },
    # read-api's login (t276). Its password is OWNED BY TERRAFORM (random_password → packiot/<env>/internal-keys
    # .readapi_ro_password, mirrored into READAPI_RO_PASSWORD in /opt/packiot/.env), so this script only APPLIES it to
    # the role: it never generates, writes or rotates it. Found 2026-10-15: the transplant creates readapi_ro LOGIN
    # without a password and no go-live step set one (the rehearsal did it in a clone-only script).
    "readapi-ro": {
        "role": "readapi_ro",
        "migration": "t276-readapi-ro-nobypassrls",
        "staging_host": "pgbouncer",
        "settings": {},
        "password_from": ("internal-keys", "readapi_ro_password"),
    },
}


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def dotenv_value(path, key):
    with open(path) as f:
        for line in f:
            if line.startswith(key + "="):
                return line.rstrip("\n").split("=", 1)[1].strip().strip('"').strip("'")
    die(f"{key} not found in {path}")


def psql(a, host, user, password, sql):
    """Run sql (stdin) as user on host; return stdout. The password travels in the child's env, not argv."""
    cmd = ["docker", "run", "--rm", "-i", "--network", a.network, "-e", "PGPASSWORD", PSQL_IMAGE,
           "psql", "-h", host, "-p", str(a.db_port), "-U", user, "-d", a.db_name,
           "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-f", "-"]
    r = subprocess.run(cmd, input=sql, text=True, capture_output=True, env={**os.environ, "PGPASSWORD": password})
    if r.returncode != 0:
        die(f"psql as {user}@{host} failed: {r.stderr.strip()}")
    return r.stdout.strip()


def aws(a, *args, check=True):
    r = subprocess.run(["aws", "--region", a.region, "secretsmanager", *args], text=True, capture_output=True)
    if check and r.returncode != 0:
        die(f"aws secretsmanager {args[0]} failed: {r.stderr.strip()}")
    return r


def scram_verifier(password, iterations=4096):
    """The SCRAM-SHA-256 verifier Postgres stores (RFC 5802/7677; same as psql's \\password).
    A hex password is plain ASCII, so SASLprep is the identity."""
    salt = secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b64 = lambda b: base64.b64encode(b).decode()
    return f"SCRAM-SHA-256${iterations}:{b64(salt)}${b64(stored_key)}:{b64(server_key)}"


def put_secret(a, exists, payload):
    # The value goes through a 0600 file in RAM (/dev/shm), never argv, then is removed.
    fd, path = tempfile.mkstemp(dir="/dev/shm" if os.path.isdir("/dev/shm") else None)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        if exists:
            aws(a, "put-secret-value", "--secret-id", a.secret_id, "--secret-string", f"file://{path}")
        else:
            aws(a, "create-secret", "--name", a.secret_id, "--secret-string", f"file://{path}",
                "--description", f"{a.service} least-privilege DB login (t-{a.service}-role)")
    finally:
        os.unlink(path)


def main():
    sys.stdout.reconfigure(line_buffering=True)  # step lines before any ERROR on stderr
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--service", required=True, choices=sorted(ROLES))
    p.add_argument("--env", default="staging", choices=["staging", "production"])
    p.add_argument("--secret-id", help="default packiot/<env>/<service>-db-creds")
    p.add_argument("--db-host", help="host written to the secret (the service's path); default: the existing "
                                     "secret's host, else the service's staging host")
    p.add_argument("--admin-host", help=f"DB host for the admin steps; default {STAGING_DB_HOST} on staging")
    p.add_argument("--db-port", type=int, default=5432)
    p.add_argument("--db-name", default="packiot_analytics")
    p.add_argument("--dotenv", default="/opt/packiot/.env")
    p.add_argument("--network", default="stack_packiot-net")
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify only: role attributes + login with the secret")
    mode.add_argument("--rotate", action="store_true", help="generate a new password even if the secret exists")
    a = p.parse_args()
    spec = ROLES[a.service]
    role = spec["role"]
    external = spec.get("password_from")   # (secret suffix, json key): a password this script must not own
    if external and a.rotate:
        die(f"{a.service}'s password is owned by terraform ({external[0]}.{external[1]}): rotate it there")
    a.secret_id = a.secret_id or f"packiot/{a.env}/{external[0] if external else a.service + '-db-creds'}"

    current = None
    r = aws(a, "get-secret-value", "--secret-id", a.secret_id, "--query", "SecretString", "--output", "text",
            check=False)
    if r.returncode == 0:
        current = json.loads(r.stdout)
    elif "ResourceNotFoundException" not in r.stderr:
        die(f"get-secret-value {a.secret_id}: {r.stderr.strip()}")
    if external:
        if not (current or {}).get(external[1]):
            die(f"{a.secret_id} has no {external[1]} field")
        current = {"password": current[external[1]]}   # only this field; the secret's other keys are not ours
    staging = a.env == "staging"
    a.db_host = a.db_host or (current or {}).get("host") or (spec["staging_host"] if staging else None)
    a.admin_host = a.admin_host or (STAGING_DB_HOST if staging else None)
    if not a.db_host or not a.admin_host:
        die("--db-host and --admin-host are required for production")

    admin_user = dotenv_value(a.dotenv, "POSTGRES_USER")
    admin_pw = dotenv_value(a.dotenv, "POSTGRES_PASSWORD")

    # 1. the migration ran
    attrs = psql(a, a.admin_host, admin_user, admin_pw,
                 f"SELECT rolcanlogin, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = '{role}';")
    if attrs != "t|f|f":
        die(f"role {role} missing or wrong attributes ({attrs or 'absent'}; want login t, super f, bypassrls f): "
            f"apply db/migrations/{spec.get('migration', f't-{a.service}-role')}/01-up.sql first")
    print(f"1. role {role}: LOGIN, NOSUPERUSER, NOBYPASSRLS")

    if not a.check:
        # 2. the secret
        if external:
            password = current["password"]
            print(f"2. password from {a.secret_id}.{external[1]} (terraform-owned; not written)")
        elif current and not a.rotate:
            password = current.get("password") or die(f"{a.secret_id} has no password field")
            print(f"2. secret {a.secret_id}: exists, password reused")
        else:
            password = secrets.token_hex(32)
            put_secret(a, current is not None, {"host": a.db_host, "port": a.db_port, "user": role,
                                                 "password": password, "name": a.db_name})
            print(f"2. secret {a.secret_id}: {'new version (rotated)' if current else 'created'} (host {a.db_host})")
        # 3. the role's password, as a verifier
        psql(a, a.admin_host, admin_user, admin_pw,
             "SET log_statement = 'none';\nSET log_min_duration_statement = -1;\n"
             f"ALTER ROLE {role} PASSWORD '{scram_verifier(password)}';\n")
        print(f"3. {role} password set (SCRAM verifier; plaintext not sent)")
        current = {**(current or {}), "password": password}
    elif not current:
        die(f"secret {a.secret_id} does not exist")

    # 4. log in as the role with the secret's password, through the service's own path
    names = sorted(spec["settings"])
    cols = ", ".join(["current_user"] + [f"current_setting('{n}')" for n in names])
    got = psql(a, a.db_host, role, current["password"], f"SELECT {cols};")
    want = "|".join([role] + [spec["settings"][n] for n in names])
    if got != want:
        die(f"login check returned {got!r}; want {want!r}")
    fp = hashlib.sha256(current["password"].encode()).hexdigest()[:12]
    defaults = ", ".join("%s=%s" % (n, spec["settings"][n]) for n in names)
    print(f"4. login OK as {role} via {a.db_host}/{a.db_name} ({defaults}; secret fingerprint {fp})")
    if a.rotate:
        print(f"   next: recreate {a.service} so it reads the new password "
              f"(docker compose -f compose.{a.env}.yml -p stack up -d --force-recreate {a.service})")


if __name__ == "__main__":
    main()
