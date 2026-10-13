#!/usr/bin/env python3
"""check-amqp-least-priv.py — keep broker clients off the RabbitMQ admin.

Two guards, both static (no broker, no .env, no secrets):

1. Credential source. In compose.staging.yml / compose.production.yml, every
   service that names a least-privilege RABBITMQ_SECRET_ID must actually read
   its AMQP creds from that secret. A service with CREDS_SOURCE=env reads
   RABBITMQ_USER/RABBITMQ_PASSWORD from .env instead — on staging that is the
   broker ADMIN (it is also RABBITMQ_DEFAULT_USER). Such a service must set
   AMQP_CREDS_SOURCE to something other than "env", and its code must honour
   that variable (grep of its build context).

2. Permission coverage. Every exchange and queue stream-engine declares, binds,
   publishes to or consumes (names taken from its staging environment, plus
   the per-tenant triple for each tenant in WORKER_TENANT_ALLOWLIST) must match
   the stream-engine user's configure/write/read regexes in
   monitoring/rabbitmq/definitions.template.json. RabbitMQ matches those regexes
   unanchored (re:run), so re.search is the faithful model. All three
   permissions are required for every name: exchanges are declared (configure),
   bound to (read), published to / used as DLX (write); queues are declared
   (configure), bound (write), consumed / declared with a DLX (read).
   See services/stream-engine/internal/amqp/topology.go and consumer.go.

Run from anywhere in the repo: scripts/ci/check-amqp-least-priv.py
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
COMPOSE_FILES = ["compose.staging.yml", "compose.production.yml"]
TEMPLATE = ROOT / "monitoring/rabbitmq/definitions.template.json"
SE_USER = "stream-engine"

errors = []


def compose(path):
    out = subprocess.check_output(
        ["docker", "compose", "-f", str(ROOT / path), "config", "--no-interpolate", "--format", "json"],
        text=True, cwd=ROOT)
    return json.loads(out)["services"]


def env_of(svc):
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) if "=" in e else (e, "") for e in env)
    return {k: ("" if v is None else str(v)) for k, v in env.items()}


def default_of(value):
    """'${VAR:-a,b}' → 'a,b'; plain values pass through."""
    m = re.fullmatch(r"\$\{[A-Z0-9_]+:?-([^}]*)\}", value)
    return m.group(1) if m else value


def build_context(svc):
    b = svc.get("build")
    if isinstance(b, dict):
        b = b.get("context")
    return ROOT / b if b else None


# ── 1. credential source ─────────────────────────────────────────────────────
staging_services = None
for path in COMPOSE_FILES:
    services = compose(path)
    if path == "compose.staging.yml":
        staging_services = services
    for name, svc in sorted(services.items()):
        env = env_of(svc)
        if "RABBITMQ_SECRET_ID" not in env or env.get("CREDS_SOURCE") != "env":
            continue
        amqp_src = env.get("AMQP_CREDS_SOURCE", "")
        if amqp_src in ("", "env"):
            errors.append(f"{path}: {name} sets CREDS_SOURCE=env with RABBITMQ_SECRET_ID but AMQP_CREDS_SOURCE="
                          f"{amqp_src or '<unset>'} — AMQP creds would come from .env (the broker admin)")
            continue
        ctx = build_context(svc)
        honoured = ctx is not None and ctx.is_dir() and subprocess.run(
            ["git", "grep", "-q", "AMQP_CREDS_SOURCE", "--", "*.go"], cwd=ctx).returncode == 0
        if not honoured:
            errors.append(f"{path}: {name} sets AMQP_CREDS_SOURCE but its code ({ctx}) never reads it")

# ── 2. stream-engine permission coverage ─────────────────────────────────────
perms = [p for p in json.loads(TEMPLATE.read_text())["permissions"] if p["user"] == SE_USER]
if len(perms) != 1:
    errors.append(f"{TEMPLATE.relative_to(ROOT)}: expected exactly one permission entry for {SE_USER}, got {len(perms)}")
else:
    p = perms[0]
    env = env_of(staging_services["stream-engine"])
    exchanges = [env[k] for k in ("SOURCE_EXCHANGE", "RETRY_EXCHANGE", "FAILED_EXCHANGE")]
    queues = [env[k] for k in ("WORKER_QUEUE", "RETRY_QUEUE", "FAILED_QUEUE")]
    tenants = [t.strip() for t in default_of(env.get("WORKER_TENANT_ALLOWLIST", "")).split(",") if t.strip()]
    for t in tenants:
        q = f"{env['WORKER_QUEUE']}-{t}"
        queues += [q, f"{q}-retry-30s", f"{q}-failed"]
    for res in exchanges + queues:
        for kind in ("configure", "write", "read"):
            if not re.search(p[kind], res):
                errors.append(f"{SE_USER} lacks {kind} on '{res}' (regex {p[kind]!r})")
    if not errors:
        print(f"ok: {SE_USER} covers {len(exchanges)} exchanges + {len(queues)} queues "
              f"(tenants: {','.join(tenants)})")

if errors:
    print("AMQP least-privilege check FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print("ok: no compose service resolves AMQP creds from .env while naming a least-priv secret")
