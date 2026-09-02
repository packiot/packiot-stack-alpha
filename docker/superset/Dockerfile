# docker/superset/Dockerfile — derived Superset image for the W2 embedded-BI overlay.
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: the pinned upstream `apache/superset:4.1.1` (arm64) ships with
# NO PostgreSQL driver and without the extra Flask libs our superset_config.py
# imports, so the bare image cannot boot our config:
#   * psycopg2  → SQLALCHEMY_DATABASE_URI (metadata DB) + the analytics DB
#                 connection are both PostgreSQL; without a driver Superset dies
#                 at "db upgrade".
#   * flask-cors→ ENABLE_CORS / CORS_OPTIONS (front4 SPA cross-origin embed).
#   * Authlib   → AUTH_OAUTH Cognito OIDC provider (Flask-AppBuilder OAuth path).
#   * flask-talisman → TALISMAN_CONFIG (CSP frame-ancestors — the embed hinge) +
#                 the security-header posture.
#
# Build ON the self-hosted t4g runner (arm64). All four wheels resolve on
# linux/arm64: psycopg2-binary ships manylinux aarch64 wheels; the other three
# are pure-Python. Versions are pinned to releases known-compatible with the
# Flask 2.3 / Werkzeug 2.3 stack that Superset 4.1.1  pins.
#
# compose.superset.yml references this via `build:` + a local `image:` tag so the
# image is built once and reused by web/worker/init (see the x-superset-build
# anchor there).

FROM apache/superset:4.1.1

# pip install needs root; the base image's runtime user is `superset`.
USER root

RUN pip install --no-cache-dir \
      "psycopg2-binary==2.9.10" \
      "flask-cors==4.0.2" \
      "Authlib==1.3.2" \
      "flask-talisman==1.1.0"

# Drop back to the unprivileged runtime user the base image ships (uid 1000).
USER superset
