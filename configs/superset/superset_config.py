# configs/superset/superset_config.py
# W2 embedded-Superset — configuration SKETCH (INERT until the W2 go decision).
# Bind-mounted read-only into the superset containers at
#   /app/pythonpath/superset_config.py
# (Superset auto-imports any superset_config.py found on PYTHONPATH.)
#
# This is a DESIGN sketch — NOTHING here is deployed. All secrets come from the
# environment (fed from Secrets Manager into .env, like every other secret in the
# stack); NONE are committed. See docs/plans/w2-embedded-superset.md §1 + §2.
#
# The SAME file is used by every Superset process (web, celery worker, beat) so
# they share SECRET_KEY, the metadata DB, the guest-token signing key, and the
# Celery/Redis wiring. Differences between processes are only in their entrypoint
# command (see the compose snippets in the spec), not in this config.

import os

# ── Core secrets ─────────────────────────────────────────────────────────────
# SECRET_KEY signs the Flask session cookie AND (by default) is the fallback for
# the guest-token key. It MUST be stable across restarts and IDENTICAL on every
# Superset process — a rotated/mismatched key invalidates all sessions and
# in-flight guest tokens. 64 hex chars from Secrets Manager.
SECRET_KEY = os.environ["SUPERSET_SECRET_KEY"]

# Guest tokens (the embedded-viewer path) are signed with their OWN key so it can
# be rotated independently of the session key. edge-api does NOT need this value —
# it asks Superset to MINT the guest token over the API; only Superset signs it.
GUEST_TOKEN_JWT_SECRET = os.environ["SUPERSET_GUEST_TOKEN_JWT_SECRET"]
GUEST_TOKEN_JWT_EXP_SECONDS = 300          # 5 min; front4 re-mints on expiry
GUEST_ROLE_NAME = "Public"                 # the (locked-down) role guest tokens assume

# ── Metadata DB (Superset's own state — SEPARATE from the analytics DB) ───────
# The dedicated `superset` role+DB on the r7g, created by superset-db-init (mirrors
# authentik). This is NOT where the OEE data lives — the analytics DB (bi.* views,
# read as superset_ro) is registered SEPARATELY inside the Superset UI as a
# "database", never here.
#
# CONNECTS UPSTREAM-DIRECT to the r7g (POSTGRES_HOST_UPSTREAM), NOT via pgbouncer.
# WHY: the stack's pgbouncer routes ONLY `packiot` and `packiot_shadow` (the
# entrypoint generates a route from DB_NAME=packiot and the compose command sed-adds
# `packiot_shadow`; there is no wildcard and no `superset` route). Adding one would
# mean editing the base `pgbouncer` service `command:` in compose.staging.yml /
# compose.production.yml — a change to the shared DB path every stack service
# depends on, well outside this profile-gated overlay. The metadata DB is
# low-traffic (users, dashboards, RLS filters, embed configs — not analytics
# queries), so it gains nothing from pooling, and a direct SESSION connection is
# also the safer home for Alembic `db upgrade` migrations and SQLAlchemy session
# state under pgbouncer's transaction-pooling mode (the same reason hasura is kept
# pgbouncer-direct in the base stack). superset-db-init already targets this same
# upstream host to CREATE the role+DB, so the metadata DB lives there anyway.
SUPERSET_METADATA_DB_HOST = os.environ.get("POSTGRES_HOST_UPSTREAM", "pgbouncer")
SQLALCHEMY_DATABASE_URI = (
    "postgresql+psycopg2://superset:%s@%s:5432/superset"
    % (os.environ["SUPERSET_DB_PASSWORD"], SUPERSET_METADATA_DB_HOST)
)

# ── Redis (cache + Celery broker/results) ─────────────────────────────────────
# Dedicated `superset-redis` (NOT the app-redis cache-aside instance — that runs
# allkeys-lru eviction which would silently DROP Celery task messages). Logical
# DBs: 0 = cache, 1 = Celery results, 2 = Celery broker.
REDIS_HOST = os.environ.get("SUPERSET_REDIS_HOST", "superset-redis")
REDIS_PORT = int(os.environ.get("SUPERSET_REDIS_PORT", "6379"))

CACHE_CONFIG = {
    "CACHE_TYPE": "RedisCache",
    "CACHE_DEFAULT_TIMEOUT": 300,
    "CACHE_KEY_PREFIX": "superset_cache_",
    "CACHE_REDIS_URL": f"redis://{REDIS_HOST}:{REDIS_PORT}/0",
}
DATA_CACHE_CONFIG = CACHE_CONFIG            # chart/query result cache
FILTER_STATE_CACHE_CONFIG = CACHE_CONFIG    # required for dashboards/embeds
EXPLORE_FORM_DATA_CACHE_CONFIG = CACHE_CONFIG


# Async query results backend — SQL Lab async + Celery share this.
from cachelib.redis import RedisCache  # noqa: E402
RESULTS_BACKEND = RedisCache(
    host=REDIS_HOST, port=REDIS_PORT, key_prefix="superset_results", db=1
)


class CeleryConfig:
    broker_url = f"redis://{REDIS_HOST}:{REDIS_PORT}/2"
    result_backend = f"redis://{REDIS_HOST}:{REDIS_PORT}/1"
    imports = ("superset.sql_lab", "superset.tasks.scheduler")
    worker_prefetch_multiplier = 1
    task_acks_late = True


CELERY_CONFIG = CeleryConfig

# ── Feature flags ─────────────────────────────────────────────────────────────
FEATURE_FLAGS = {
    "EMBEDDED_SUPERSET": True,      # unlocks the guest-token / embedded-SDK path
    "DASHBOARD_RBAC": True,         # per-role dashboard access (authoring surface)
    "ALERT_REPORTS": True,          # needs the Celery worker + beat
    "GLOBAL_ASYNC_QUERIES": False,  # keep off until the ws/results plumbing is load-tested
}
# NOTE: native Row Level Security ("ROW_LEVEL_SECURITY") is GA / on by default in
# current Superset — it is configured in the UI (Settings → Row Level Security),
# not via a feature flag. Both the guest-token clause AND the authoring role
# filters ride that same RLS machinery.

# ── Embeddability: CSP frame-ancestors (Talisman), NOT X-Frame-Options ────────
# front4 loads Superset in an <iframe>. We MUST allow that origin as a
# frame-ancestor and MUST NOT emit X-Frame-Options (it has no per-origin allow
# and would blank the iframe). Talisman owns the response security headers.
FRONT4_ORIGIN = os.environ.get("SUPERSET_FRAME_ANCESTOR", "https://front.prod.packiot.app")
ENABLE_PROXY_FIX = True             # behind nginx + CloudFront — trust X-Forwarded-*
TALISMAN_ENABLED = True
TALISMAN_CONFIG = {
    "content_security_policy": {
        "default-src": ["'self'"],
        "img-src": ["'self'", "data:", "blob:"],
        "worker-src": ["'self'", "blob:"],
        "connect-src": ["'self'"],
        "object-src": ["'none'"],
        "style-src": ["'self'", "'unsafe-inline'"],
        "script-src": ["'self'", "'unsafe-inline'", "'unsafe-eval'"],
        # THE embed hinge — who may frame Superset:
        "frame-ancestors": ["'self'", FRONT4_ORIGIN],
    },
    "force_https": False,           # TLS terminates at nginx/CloudFront
    "frame_options": None,          # do NOT set X-Frame-Options (see above)
    "session_cookie_secure": True,
}
# Cross-site iframe → the Superset session cookie must be SameSite=None; Secure.
SESSION_COOKIE_SAMESITE = "None"
SESSION_COOKIE_SECURE = True

# ── CORS (scoped to the front4 SPA origin) ────────────────────────────────────
ENABLE_CORS = True
CORS_OPTIONS = {
    "supports_credentials": True,
    "origins": [FRONT4_ORIGIN],
    "allow_headers": ["Authorization", "Content-Type", "X-CSRFToken"],
    "resources": ["/api/*", "/embedded/*"],
}
WTF_CSRF_ENABLED = True
WTF_CSRF_EXEMPT_LIST = ["superset.views.core.log"]  # keep CSRF ON for everything else

# ── Authoring auth: Cognito as an OIDC/OAuth2 provider (Flask-AppBuilder) ─────
# This is what gives each supervisor a REAL Superset account (Explore + SQL Lab)
# so they can BUILD their own reports — the requirement the guest-token/viewer
# path alone cannot satisfy. New users self-register as Gamma_BI (create on the
# bi.* datasets, no admin). The CUSTOM security manager (below) additionally binds
# each user to their per-tenant RLS on first login.
# AUTH MODE — FAIL-SAFE DEFAULT: database login (admin username/password form).
#
# The Cognito OIDC/OAuth2 authoring-SSO path below is engaged ONLY when it is
# BOTH explicitly requested (SUPERSET_AUTH_MODE=oauth) AND actually wired (a
# non-empty SUPERSET_COGNITO_CLIENT_ID). Otherwise we fall back to AUTH_DB so the
# standard username/password form renders and the bootstrapped admin can log in.
#
# WHY THIS GATE EXISTS: with AUTH_TYPE=AUTH_OAUTH and an UNwired Cognito client
# (empty client id/secret/issuer — the state we shipped), FAB renders an SSO-only
# page ("Sign in with Cognito") with NO DB form and a dead OAuth button — locking
# every admin out. DB login is the safe default until a real Cognito app client +
# the superset_cognito_* secrets are provisioned. See docs/plans/w2-embedded-superset.md.
#
# The guest-token / embedded-SDK path (EMBEDDED_SUPERSET, GUEST_TOKEN_*, the
# DB_CONNECTION_MUTATOR tenant stamp) is INDEPENDENT of this UI login mode and
# keeps working in either — guest tokens are signed with GUEST_TOKEN_JWT_SECRET,
# not minted through the FAB login form.
_SUPERSET_AUTH_MODE = os.environ.get("SUPERSET_AUTH_MODE", "db").strip().lower()
_SUPERSET_COGNITO_CLIENT_ID = os.environ.get("SUPERSET_COGNITO_CLIENT_ID", "").strip()
_USE_COGNITO_OAUTH = _SUPERSET_AUTH_MODE == "oauth" and bool(_SUPERSET_COGNITO_CLIENT_ID)

if _USE_COGNITO_OAUTH:
    # ── Authoring auth: Cognito as an OIDC/OAuth2 provider (Flask-AppBuilder) ──
    # Gives each supervisor a REAL Superset account (Explore + SQL Lab) so they
    # can BUILD their own reports. New users self-register as Gamma_BI. The CUSTOM
    # security manager (further below) additionally binds each user to their
    # per-tenant RLS on first login.
    from flask_appbuilder.security.manager import AUTH_OAUTH  # noqa: E402

    AUTH_TYPE = AUTH_OAUTH
    AUTH_USER_REGISTRATION = True
    AUTH_USER_REGISTRATION_ROLE = "Gamma_BI"     # least-privilege authoring role (see spec §2.3)

    COGNITO_ISSUER = os.environ["SUPERSET_COGNITO_ISSUER"]  # https://cognito-idp.us-east-1.amazonaws.com/<pool-id>
    OAUTH_PROVIDERS = [
        {
            "name": "cognito",
            "icon": "fa-lock",
            "token_key": "access_token",
            "remote_app": {
                "client_id": _SUPERSET_COGNITO_CLIENT_ID,
                "client_secret": os.environ["SUPERSET_COGNITO_CLIENT_SECRET"],
                "server_metadata_url": f"{COGNITO_ISSUER}/.well-known/openid-configuration",
                "api_base_url": f"{COGNITO_ISSUER}/",
                "client_kwargs": {"scope": "openid email profile"},
            },
        }
    ]

    # Map a Cognito group claim → Superset roles (coarse RBAC). The FINE per-tenant
    # binding is done by the custom security manager, not here.
    AUTH_ROLES_MAPPING = {
        "factory-supervisor": ["Gamma_BI"],
        "packiot-bi-admin": ["Admin"],
    }
    AUTH_ROLES_SYNC_AT_LOGIN = True
else:
    # ── Database login (DEFAULT): standard username/password form via FAB ──────
    # The bootstrapped admin (SUPERSET_GUESTTOKEN_ADMIN_USER, created by
    # `superset fab create-admin` from Secrets Manager packiot/production/app)
    # logs in here. No self-registration — the login form is the only entry.
    from flask_appbuilder.security.manager import AUTH_DB  # noqa: E402

    AUTH_TYPE = AUTH_DB
    AUTH_USER_REGISTRATION = False

# ── HARDENING: authors get NO native SQL against the analytics DB ─────────────
# RLS rewrites DATASET queries only. A user with SQL Lab + raw analytics-DB access
# could SELECT straight off a base table and BYPASS the dataset-scoped RLS. So the
# authoring role (Gamma_BI) is a cloned Gamma with SQL-Lab perms STRIPPED (see
# custom_sso_security_manager.py::_harden_gamma_bi), AND the analytics database is
# registered with expose_in_sqllab=False + allow_dml=False (belt-and-suspenders).
# Keep GLOBAL_ASYNC_QUERIES / SQL Lab available ONLY to the internal Admin role.
SQLLAB_CTAS_NO_LIMIT = False
# Guard rails on ad-hoc / self-service load (see spec §6.2 TimescaleDB risk):
ROW_LIMIT = 50_000
SQL_MAX_ROW = 100_000

# Bind id_enterprise → a per-tenant RLS filter on first/every OIDC login.
# The class lives next to this file (configs/superset/custom_sso_security_manager.py,
# also on PYTHONPATH). See the spec §2.3 for its body.
#
# ONLY wired in OAuth mode: it exists to bind per-tenant RLS on OIDC login. In DB
# mode there is no OIDC login to hook, so wiring it would only add dead
# oauth_user_info/auth_user_oauth overrides. The guest-token embed path does NOT
# use the custom manager (it rides GUEST_TOKEN_JWT_SECRET + the guest role), so
# leaving it unwired here does not affect embeds.
if _USE_COGNITO_OAUTH:
    from custom_sso_security_manager import CognitoTenantSecurityManager  # noqa: E402
    CUSTOM_SECURITY_MANAGER = CognitoTenantSecurityManager

# ── Analytics DB connection is NOT configured here ────────────────────────────
# The `bi` read surface (read as superset_ro) is registered as a Superset
# "database" via the UI/API AFTER boot — deliberately not in code, so the
# read-only analytics credential is managed as Superset-owned encrypted state,
# never conflated with this metadata connection.

# ── Per-request tenant GUC stamp — makes Postgres RLS a live CO-ENFORCER ───────
# The bi.* datasets read RLS-protected base tables through a NOBYPASSRLS definer
# view (bi_owner). Postgres RLS (db/superset/02-tenant-rls.sql) filters on the
# session GUC `app.tenant_id`; with the GUC UNSET it fail-closes to ZERO rows
# (spec §3.2). Superset serves the embed path from a SINGLE pooled `superset_ro`
# connection, so unless we stamp `app.tenant_id` per request, every guest-token
# chart-data query would deny-all (0 rows) — Layer-2 would over-block instead of
# co-enforce. DB_CONNECTION_MUTATOR runs per query execution WITH the caller's
# identity in flask.g; we derive the tenant from the caller's RLS (the guest
# token's `id_enterprise = <id>` clause for the embed path, or the per-tenant
# authoring RLS role) and stamp it as a libpq startup option, so each tenant gets
# its own pooled connection with the correct GUC. If no tenant can be derived we
# stamp NOTHING → GUC stays unset → deny-all (fail-closed). Only the analytics DB
# (`packiot`) is stamped; the metadata DB (`superset`) is never touched.
import re as _tenant_re  # noqa: E402
from flask import g as _flask_g  # noqa: E402


def _caller_tenant_id():
    """The id_enterprise of the current caller, from their RLS rules, or None."""
    user = getattr(_flask_g, "user", None)
    if user is None:
        return None
    for rule in (getattr(user, "rls", None) or []):
        clause = rule.get("clause") if isinstance(rule, dict) else getattr(rule, "clause", "")
        m = _tenant_re.search(r"id_enterprise\s*=\s*(\d+)", clause or "")
        if m:
            return int(m.group(1))
    return None


def DB_CONNECTION_MUTATOR(uri, params, username, security_manager, source):  # noqa: N802,E501
    try:
        if getattr(uri, "database", None) == "packiot":
            tenant = _caller_tenant_id()
            if tenant is not None:
                connect_args = dict(params.get("connect_args") or {})
                existing = connect_args.get("options", "")
                connect_args["options"] = (existing + f" -c app.tenant_id={tenant}").strip()
                params = {**params, "connect_args": connect_args}
    except Exception:  # never let stamping break a query — worst case = deny-all
        pass
    return uri, params
