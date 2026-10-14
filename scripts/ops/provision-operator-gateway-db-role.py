#!/usr/bin/env python3
"""Provision (or rotate) the operator_gateway DB login on the HOST — the password never leaves it.

Run on the stack's app host as root, AFTER db/migrations/t-operator-gateway-role/01-up.sql is applied
(services/operator-gateway/README.md § Provisioning the DB role has the full ordered runbook):

  1. checks the role exists and is LOGIN, NOSUPERUSER, NOBYPASSRLS (else: apply the migration first);
  2. Secrets Manager packiot/<env>/operator-gateway-db-creds: reuses the password if the secret exists,
     otherwise generates one (256-bit, hex) and creates the secret {host, port, user, password, name}
     — the shape services/operator-gateway/internal/secrets reads. --rotate always generates a new one;
  3. sets the role's password as a SCRAM-SHA-256 verifier computed here, so the plaintext is never sent
     to Postgres (nothing to leak into the server log or pg_stat_statements); log_statement is off too;
  4. logs in AS operator_gateway with the secret's password and checks current_user + read-only default.

Prints ids, fingerprints and results, never a password. Admin login: POSTGRES_USER/POSTGRES_PASSWORD
from the .env (read line by line, never sourced). psql runs in postgres:15-alpine on the stack network.

  provision-operator-gateway-db-role.py                 # staging: create-or-reuse, set, verify
  provision-operator-gateway-db-role.py --check         # verify only (steps 1 + 4)
  provision-operator-gateway-db-role.py --rotate        # new password; then recreate operator-gateway
  provision-operator-gateway-db-role.py --env production --db-host <prod DB host>
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

ROLE = "operator_gateway"
PSQL_IMAGE = "postgres:15-alpine"


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def dotenv_value(path, key):
    with open(path) as f:
        for line in f:
            if line.startswith(key + "="):
                return line.rstrip("\n").split("=", 1)[1].strip().strip('"').strip("'")
    die(f"{key} not found in {path}")


def psql(a, user, password, sql):
    """Run sql (stdin) as user; return stdout. The password travels in the child's env, not argv."""
    cmd = ["docker", "run", "--rm", "-i", "--network", a.network, "-e", "PGPASSWORD", PSQL_IMAGE,
           "psql", "-h", a.db_host, "-p", str(a.db_port), "-U", user, "-d", a.db_name,
           "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-f", "-"]
    r = subprocess.run(cmd, input=sql, text=True, capture_output=True, env={**os.environ, "PGPASSWORD": password})
    if r.returncode != 0:
        die(f"psql as {user} failed: {r.stderr.strip()}")
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
                "--description", "operator-gateway least-privilege DB login (t-operator-gateway-role)")
    finally:
        os.unlink(path)


def main():
    sys.stdout.reconfigure(line_buffering=True)  # step lines before any ERROR on stderr
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--env", default="staging", choices=["staging", "production"])
    p.add_argument("--secret-id", help="default packiot/<env>/operator-gateway-db-creds")
    p.add_argument("--db-host", help="default: the existing secret's host, else 10.10.10.89 on staging")
    p.add_argument("--db-port", type=int, default=5432)
    p.add_argument("--db-name", default="packiot_analytics")
    p.add_argument("--dotenv", default="/opt/packiot/.env")
    p.add_argument("--network", default="stack_packiot-net")
    p.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify only: role attributes + login with the secret")
    mode.add_argument("--rotate", action="store_true", help="generate a new password even if the secret exists")
    a = p.parse_args()
    a.secret_id = a.secret_id or f"packiot/{a.env}/operator-gateway-db-creds"

    current = None
    r = aws(a, "get-secret-value", "--secret-id", a.secret_id, "--query", "SecretString", "--output", "text",
            check=False)
    if r.returncode == 0:
        current = json.loads(r.stdout)
    elif "ResourceNotFoundException" not in r.stderr:
        die(f"get-secret-value {a.secret_id}: {r.stderr.strip()}")
    if not a.db_host:
        a.db_host = (current or {}).get("host") or ("10.10.10.89" if a.env == "staging" else None)
        if not a.db_host:
            die("--db-host is required for production")

    admin_user = dotenv_value(a.dotenv, "POSTGRES_USER")
    admin_pw = dotenv_value(a.dotenv, "POSTGRES_PASSWORD")

    # 1. the migration ran
    attrs = psql(a, admin_user, admin_pw,
                 f"SELECT rolcanlogin, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = '{ROLE}';")
    if attrs != "t|f|f":
        die(f"role {ROLE} missing or wrong attributes ({attrs or 'absent'}; want login t, super f, bypassrls f): "
            f"apply db/migrations/t-operator-gateway-role/01-up.sql first")
    print(f"1. role {ROLE}: LOGIN, NOSUPERUSER, NOBYPASSRLS")

    if not a.check:
        # 2. the secret
        if current and not a.rotate:
            password = current.get("password") or die(f"{a.secret_id} has no password field")
            print(f"2. secret {a.secret_id}: exists, password reused")
        else:
            password = secrets.token_hex(32)
            put_secret(a, current is not None, {"host": a.db_host, "port": a.db_port, "user": ROLE,
                                                 "password": password, "name": a.db_name})
            print(f"2. secret {a.secret_id}: {'new version (rotated)' if current else 'created'}")
        # 3. the role's password, as a verifier
        psql(a, admin_user, admin_pw,
             "SET log_statement = 'none';\nSET log_min_duration_statement = -1;\n"
             f"ALTER ROLE {ROLE} PASSWORD '{scram_verifier(password)}';\n")
        print(f"3. {ROLE} password set (SCRAM verifier; plaintext not sent)")
        current = {"password": password}
    elif not current:
        die(f"secret {a.secret_id} does not exist")

    # 4. log in as the role with the secret's password
    who = psql(a, ROLE, current["password"],
               "SELECT current_user, current_setting('default_transaction_read_only');")
    if who != f"{ROLE}|on":
        die(f"login check returned {who!r}; want '{ROLE}|on'")
    fp = hashlib.sha256(current["password"].encode()).hexdigest()[:12]
    print(f"4. login OK as {ROLE} on {a.db_host}/{a.db_name} (read-only default on; secret fingerprint {fp})")
    if a.rotate:
        print("   next: recreate operator-gateway so it reads the new password "
              "(docker compose -f compose.staging.yml -p stack up -d --force-recreate operator-gateway)")


if __name__ == "__main__":
    main()
