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
# The dedicated `superset` role+DB on the r7g, created by db-init-bootstrap
# (mirrors authentik). Reached via pgbouncer. This is NOT where the OEE data
# lives — the analytics DB (bi.* views, read as superset_ro) is registered
# SEPARATELY inside the Superset UI as a "database", never here.
SQLALCHEMY_DATABASE_URI = (
    "postgresql+psycopg2://superset:%s@pgbouncer:5432/superset"
    % os.environ["SUPERSET_DB_PASSWORD"]
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
            "client_id": os.environ["SUPERSET_COGNITO_CLIENT_ID"],
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

# Bind id_enterprise → a per-tenant RLS filter on first/every OIDC login.
# The class lives next to this file (configs/superset/custom_sso_security_manager.py,
# also on PYTHONPATH). See the spec §2.3 for its body.
from custom_sso_security_manager import CognitoTenantSecurityManager  # noqa: E402
CUSTOM_SECURITY_MANAGER = CognitoTenantSecurityManager

# ── Analytics DB connection is NOT configured here ────────────────────────────
# The `bi` read surface (read as superset_ro) is registered as a Superset
# "database" via the UI/API AFTER boot — deliberately not in code, so the
# read-only analytics credential is managed as Superset-owned encrypted state,
# never conflated with this metadata connection.
