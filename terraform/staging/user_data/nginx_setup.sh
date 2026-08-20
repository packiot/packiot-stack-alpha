#!/bin/bash
# Installs and configures Nginx + Certbot (Let's Encrypt wildcard cert via Route53 DNS-01).
# Safe to run on a live EC2 — does NOT touch .env, Docker, or Node-RED. Idempotent.
#
# Access control: oauth2-proxy (Cognito OIDC) via nginx auth_request forward-auth
# (ADR-0034 §C). Authentik is RETIRED. Two internal subrequest endpoints live in
# snippets/oauth2-proxy.conf (/oauth2/auth = any pool user; /oauth2/auth-csadmin =
# cs-admin group only). CloudFront-fronted vhosts also include
# snippets/origin-verify.conf, which 403s any request that did not enter via
# CloudFront (X-Origin-Verify shared secret fetched from Secrets Manager at
# runtime below — never hardcoded). Deliberately-open carve-outs (mq / refdata /
# cpack-ingest / auth) omit both gates by design.
set -euo pipefail
exec > >(tee /var/log/packiot-nginx-setup.log | logger -t packiot-nginx-setup) 2>&1

echo "=== Nginx + Certbot setup starting $(date -u) ==="

STAGING_DOMAIN="${staging_domain}"
AWS_REGION="${aws_region}"

# ── X-Origin-Verify shared secret (edge origin-lock) ──────────────────────────
# Fetched at runtime from packiot/staging/app (key x_origin_verify) using the
# instance IAM role — same get_secret pattern app_init.sh uses. Kept OUT of
# terraform state and the rendered S3 object. MUST equal the custom header value
# CloudFront injects on every origin request (terraform edge.tf). If the key is
# absent/empty we log loudly but continue so nginx still boots; fix the secret
# and re-run this script standalone to close the gate.
get_secret() {
  aws secretsmanager get-secret-value \
    --secret-id "$1" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text
}
X_ORIGIN_VERIFY=$(get_secret "packiot/staging/app" | jq -r '.x_origin_verify // ""')
if [ -z "$X_ORIGIN_VERIFY" ] || [ "$X_ORIGIN_VERIFY" = "null" ]; then
  echo "WARNING: packiot/staging/app.x_origin_verify is empty — origin-verify" \
       "will 403 legitimate CloudFront traffic. Populate the secret + re-run."
fi

# ── Nginx ─────────────────────────────────────────────────────────────────────
dnf install -y nginx
systemctl enable nginx

# ── WebSocket connection map ───────────────────────────────────────────────────
# Sets $ws_connection = "upgrade" only when the client sends an Upgrade header.
# For plain HTTP requests (Upgrade is empty), $ws_connection = "close".
# This avoids sending Connection: upgrade on non-WebSocket requests, which
# confuses Grafana's Go HTTP server and causes 500 errors.
printf 'map $http_upgrade $ws_connection {\n    default upgrade;\n    "" close;\n}\n' \
  > /etc/nginx/conf.d/00-websocket.conf

nginx -t && systemctl start nginx
echo "Nginx started (vhosts written after cert is obtained)"

# ── Certbot + Let's Encrypt (DNS-01 via Route53) ──────────────────────────────
# DNS-01 challenge: Certbot creates a TXT record in Route53, Let's Encrypt
# verifies it — no inbound port 80 traffic required. The App EC2 IAM role has
# route53:ChangeResourceRecordSets permission for this to work.
pip3 install certbot certbot-dns-route53

certbot certonly \
  --dns-route53 \
  --domain "*.$STAGING_DOMAIN" \
  --domain "$STAGING_DOMAIN" \
  --email ops@packiot.com \
  --agree-tos \
  --non-interactive \
  --logs-dir /var/log/letsencrypt

if [ ! -d "/etc/letsencrypt/live/$STAGING_DOMAIN" ]; then
  echo "ERROR: certbot did not produce a cert — check /var/log/letsencrypt"
  exit 1
fi
echo "Certificate obtained: /etc/letsencrypt/live/$STAGING_DOMAIN"

# ── Shared snippet: oauth2-proxy forward-auth ─────────────────────────────────
cat > /etc/nginx/snippets/oauth2-proxy.conf <<NGINX
# oauth2-proxy (Cognito) forward-auth — shared include (ADR-0034 §C).
# /oauth2/ callback+start live on auth.<env>.packiot.app. nginx \`auth_request\`
# no-ops with a query string, so group filters are baked into proxy_pass as two
# internal endpoints. In each protected location add:
#   auth_request /oauth2/auth;           # any authenticated pool user (operator)
#   auth_request /oauth2/auth-csadmin;   # staff-only (admin UIs)
# plus:  error_page 401 = @oauth2_signin;   (403 = wrong group, falls through)

location = /oauth2/auth {
    internal;
    proxy_pass http://127.0.0.1:4180/oauth2/auth;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-Uri   \$request_uri;
    proxy_set_header X-Forwarded-Host  \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_buffer_size       32k;
    proxy_buffers           8 32k;
    proxy_busy_buffers_size 32k;
}
location = /oauth2/auth-csadmin {
    internal;
    proxy_pass http://127.0.0.1:4180/oauth2/auth?allowed_groups=cs-admin;
    proxy_set_header Host              \$host;
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-Uri   \$request_uri;
    proxy_set_header X-Forwarded-Host  \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_buffer_size       32k;
    proxy_buffers           8 32k;
    proxy_busy_buffers_size 32k;
}
location @oauth2_signin {
    return 302 https://auth.$STAGING_DOMAIN/oauth2/start?rd=\$scheme://\$http_host\$request_uri;
}
NGINX

# ── Shared snippet: X-Origin-Verify origin-lock ───────────────────────────────
cat > /etc/nginx/snippets/origin-verify.conf <<NGINX
# ADR edge origin-lock (step c): reject anything that did not enter via CloudFront.
# CloudFront stamps X-Origin-Verify on every origin request; a direct-to-EIP
# caller lacks it and gets 403. Included ONLY in CloudFront-fronted vhosts (NOT
# auth/mq/amqp/cpack-ingest, which stay direct-to-origin).
if (\$http_x_origin_verify != "$X_ORIGIN_VERIFY") {
    return 403;
}
NGINX

# ── Buffer bump for large Cognito cookies ─────────────────────────────────────
cat > /etc/nginx/conf.d/00-oauth2-buffers.conf <<NGINX
# ADR-0034 §C — Cognito ID/access/refresh tokens make the oauth2-proxy session
# cookie exceed 4kb, so it is split across several _oauth2_proxy_N cookies that
# the browser then sends (domain-wide) on every *.$STAGING_DOMAIN request.
# Raise the header buffer so nginx can parse those large request headers.
large_client_header_buffers 8 32k;
NGINX

# ── Staff-tier vhosts (cs-admin group forward-auth) ───────────────────────────
# Generated for every service whose auth tier is "csadmin". The bespoke tiers
# (api / operator / csadmin-SPA) are emitted as explicit blocks below and are
# deliberately skipped by this loop; the deliberately-open (mq / refdata /
# cpack-ingest) + auth vhosts are handled separately too.
%{ for svc, port in services ~}
%{ if lookup(service_auth, svc, "csadmin") == "csadmin" ~}
cat > /etc/nginx/conf.d/${svc}.conf <<NGINX
server {
    listen 80;
    server_name ${svc}.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${svc}.$STAGING_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;

    # Cognito forward-auth (oauth2-proxy) — replaces Authentik. Staff-only.
    include snippets/oauth2-proxy.conf;

    location / {
        auth_request /oauth2/auth-csadmin;
        auth_request_set \$auth_user  \$upstream_http_x_auth_request_user;
        auth_request_set \$auth_email \$upstream_http_x_auth_request_email;
        error_page 401 = @oauth2_signin;

        proxy_pass         http://127.0.0.1:${port};
%{ if svc == "rabbitmq" ~}
        # RabbitMQ management's Cowboy backend enforces a 4KB total-header
        # limit. The Cognito oauth2-proxy session cookie (split across
        # several _oauth2_proxy_N cookies, ADR-0034 §C) blows past that and
        # Cowboy answers 431 Request Header Fields Too Large. The browser's
        # cookie isn't needed downstream — the auth_request gate above has
        # already authorized the request, and RabbitMQ's own user/password
        # auth takes it from there — so strip it before proxying.
        proxy_set_header   Cookie "";
%{ endif ~}
        proxy_set_header   Host                 \$host;
        proxy_set_header   X-Real-IP            \$remote_addr;
        proxy_set_header   X-Forwarded-For      \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto    https;
        proxy_set_header   X-Auth-Request-User  \$auth_user;
        proxy_set_header   X-Auth-Request-Email \$auth_email;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$ws_connection;
    }
}
NGINX
%{ endif ~}
%{ endfor ~}

# ── api vhost (edge-api) ──────────────────────────────────────────────────────
# origin-verify + cs-admin gate on /, but /api/* bypasses the gate (edge-api's
# AuthMiddleware enforces its own API-key auth there). Reconciled to the oauth2
# form to match production (staging previously still emitted Authentik here).
cat > /etc/nginx/conf.d/api.conf <<NGINX
server {
    listen 80;
    server_name api.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name api.$STAGING_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;

    include snippets/oauth2-proxy.conf;

    # edge-api's AuthMiddleware enforces x-api-key auth on /api/*, so the gateway
    # gate is redundant here — bypass it. Lets external clients (prod nginx
    # mirror, factory edges) reach /api/* directly.
    location ~ ^/api/ {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
    }

    location / {
        auth_request /oauth2/auth-csadmin;
        auth_request_set \$auth_user  \$upstream_http_x_auth_request_user;
        auth_request_set \$auth_email \$upstream_http_x_auth_request_email;
        error_page 401 = @oauth2_signin;

        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$ws_connection;
    }
}
NGINX

# ── operator vhost (any authenticated pool user + API-route bypass) ───────────
cat > /etc/nginx/conf.d/operator.conf <<NGINX
server {
    listen 80;
    server_name operator.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name operator.$STAGING_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;

    # Cognito forward-auth (oauth2-proxy) — replaces Authentik. Operator is used
    # by client factory-floor users, so the SPA shell gates on ANY authenticated
    # pool user (not cs-admin). Client logins are provisioned via CS Admin.
    include snippets/oauth2-proxy.conf;

    # API routes — bypass the SSO gate. operator's SPA authenticates against
    # edge-nodered via its own JWT (POST /session → Bearer), so re-checking the
    # gateway on every XHR is redundant and breaks mid-session. The data is
    # protected by that JWT (edge-nodered validates it), not by the shell gate.
    # Keep in sync with edge-node-red/flows/API.json + operator's nginx.staging.conf.
    location ~ ^/(session|machines|edit-manual-event|add-manual-event|split-events|set-event|change-po|start-po|replace-po|create-start|language-pack|downtime-reasons|health|logo|recommended-change-times|available-production-orders|pending-events|production|solved-events|set-api-key)(/|\$) {
        proxy_pass         http://127.0.0.1:8083;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
    }

    location / {
        auth_request /oauth2/auth;
        auth_request_set \$auth_user  \$upstream_http_x_auth_request_user;
        auth_request_set \$auth_email \$upstream_http_x_auth_request_email;
        error_page 401 = @oauth2_signin;

        proxy_pass         http://127.0.0.1:8083;
        proxy_set_header   Host                 \$host;
        proxy_set_header   X-Real-IP            \$remote_addr;
        proxy_set_header   X-Forwarded-For      \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto    https;
        proxy_set_header   X-Auth-Request-User  \$auth_user;
        proxy_set_header   X-Auth-Request-Email \$auth_email;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$ws_connection;
    }
}
NGINX

# ── csadmin vhost (CS-Admin SPA — origin-verify only) ─────────────────────────
cat > /etc/nginx/conf.d/csadmin.conf <<NGINX
server {
    listen 80;
    server_name csadmin.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name csadmin.$STAGING_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;
    location / {
        proxy_pass         http://127.0.0.1:8084;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        \$ws_connection;
    }
}
NGINX

nginx -t && nginx -s reload
echo "oauth2-proxy forward-auth + origin-verify configured for all services"

# ── AMQPS TCP proxy (Nginx stream module) ────────────────────────────────────
# The stream module provides a TCP/UDP proxy separate from the http {} block.
# On AL2023 nginx is compiled with --with-stream; nginx-mod-stream provides
# the dynamic module on distros that ship it as a separate package (no-op if absent).
dnf install -y nginx-mod-stream 2>/dev/null || true

mkdir -p /etc/nginx/stream.d

# AMQP connections are long-lived (heartbeats every ~60s); set a generous
# proxy_timeout so Nginx doesn't close idle-but-healthy AMQP connections.
cat > /etc/nginx/stream.d/amqps.conf <<NGINX
server {
    listen      5671 ssl;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    proxy_pass            127.0.0.1:5672;
    proxy_timeout         3600s;
    proxy_connect_timeout 5s;
}
NGINX

# stream {} must live at the top level of nginx.conf (NOT inside http {}).
# Append it once; the guard prevents duplicate blocks on re-runs.
if ! grep -q 'stream.d' /etc/nginx/nginx.conf; then
    printf '\nstream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' \
        >> /etc/nginx/nginx.conf
fi

nginx -t && nginx -s reload
echo "AMQPS stream proxy configured on port 5671"

# ── RabbitMQ management API HTTPS proxy (deliberately open) ───────────────────
# Exposed as mq.$STAGING_DOMAIN → 127.0.0.1:15672. No origin-verify + no oauth2:
# RabbitMQ's management plugin authenticates with its own user/password, and the
# edge-client user (tags: management) POSTs to the publish API from factory edges
# that don't have amqplib. Rewritten every run (idempotent by overwrite).
cat > /etc/nginx/conf.d/mq.conf <<NGINX
server {
    listen 80;
    server_name mq.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name mq.$STAGING_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://127.0.0.1:15672;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
    }
}
NGINX

nginx -t && nginx -s reload
echo "RabbitMQ management API proxy configured at https://mq.$STAGING_DOMAIN"

# ── refdata vhost (refdata-api read plane — deliberately open, own auth) ───────
cat > /etc/nginx/conf.d/refdata.conf <<NGINX
# refdata.$STAGING_DOMAIN — refdata-api (Hasura-replacement read API).
#
# refdata-api is a JWT/X-Api-Key-authed read API consumed cross-origin by the
# front4 static SPA (https://staging.packiot.com) via fetch(). It performs its
# OWN fail-closed auth (Firebase-JWT Bearer / X-Api-Key -> 401, no DB touch).
#
# It MUST NOT sit behind Authentik SSO: a browser cross-origin fetch carrying a
# Bearer token cannot follow an interactive Authentik 302 login redirect. This
# is the SAME exemption rationale as api.conf's /api/* block and operator.conf's
# XHR routes (see their comments) — so there is NO auth_request here; nginx
# proxies straight to the container and refdata-api is the sole auth authority.
server {
    listen 80;
    server_name refdata.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name refdata.$STAGING_DOMAIN;

    # Wildcard *.$STAGING_DOMAIN cert (Let's Encrypt, dns-route53) — same
    # cert every other staging vhost uses; refdata is already a covered SAN.
    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        # CORS for the front4 staging SPA. The preflight must NOT require auth,
        # so nginx short-circuits OPTIONS with a 204 + CORS headers BEFORE the
        # request can reach refdata-api's fail-closed auth middleware. 'always'
        # ensures the ACAO header rides along on refdata's 401/4xx too, so the
        # browser can read cross-origin error bodies.
        set \$cors_origin "https://staging.packiot.com";
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin  \$cors_origin always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, OPTIONS" always;
            # x-packiot-agent + x-user are sent by front4 on every refdata call;
            # omitting them from Allow-Headers makes the browser block the request
            # (preflight fails) and front4 becomes unusable. Codifies the live fix.
            add_header Access-Control-Allow-Headers "Authorization, X-Api-Key, Content-Type, x-packiot-agent, x-user" always;
            add_header Access-Control-Max-Age      86400 always;
            add_header Content-Length 0;
            add_header Content-Type "text/plain";
            return 204;
        }
        add_header Access-Control-Allow-Origin  \$cors_origin always;
        add_header Access-Control-Allow-Headers "Authorization, X-Api-Key, Content-Type, x-packiot-agent, x-user" always;

        # refdata-api: internal container, no host publish. nginx (host) reaches
        # it by its compose-pinned bridge IP (ipv4_address: 172.18.0.26:9104).
        proxy_pass         http://172.18.0.26:9104;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
    }
}
NGINX

nginx -t && nginx -s reload
echo "refdata read-plane vhost configured at https://refdata.$STAGING_DOMAIN"

# ── superset vhost (W2 self-service BI — embedded in front4) ───────────────────
# bi.$STAGING_DOMAIN. Mirrors the prod block (terraform/production/user_data/
# nginx_setup.sh) + the refdata pattern: origin-verify (CloudFront-only) + scoped
# CORS to the front4 SPA origin. DIFFERENCES (both load-bearing for embedding):
#   * Superset has its OWN auth — short-lived guest tokens for embedded VIEWING
#     (minted by edge-api) and a Cognito-OIDC session for AUTHORING — so it does
#     NOT sit behind oauth2-proxy (a cookie forward-auth would break the iframe
#     handshake AND the OIDC redirect). No auth_request here.
#   * It MUST be iframe-embeddable: Superset's Talisman emits
#     `Content-Security-Policy: frame-ancestors https://front.$STAGING_DOMAIN`
#     (superset_config.py). We MUST NOT add X-Frame-Options — it would blank the
#     iframe. WebSocket upgrade is wired for the async-query progress channel.
# The wildcard cert (*.$STAGING_DOMAIN) already covers bi.$STAGING_DOMAIN. INERT
# until superset (:8088) is up + the profile is enabled (superset-golive-runbook).
cat > /etc/nginx/conf.d/superset.conf <<NGINX
map \$http_origin \$superset_cors {
    default "";
    "~^https://front\.$STAGING_DOMAIN\$" \$http_origin;
}
server {
    listen 80;
    server_name bi.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name bi.$STAGING_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;
    client_max_body_size 20m;            # SQL Lab / CSV upload headroom
    location / {
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin      \$superset_cors always;
            add_header Access-Control-Allow-Methods     "GET, POST, PUT, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers     "Authorization, Content-Type, X-CSRFToken" always;
            add_header Access-Control-Allow-Credentials "true" always;
            add_header Access-Control-Max-Age           86400 always;
            add_header Vary Origin always;
            return 204;
        }
        add_header Access-Control-Allow-Origin      \$superset_cors always;
        add_header Access-Control-Allow-Credentials "true" always;
        add_header Vary Origin always;
        # NOTE: NO X-Frame-Options here — Superset's Talisman CSP owns embeddability.
        proxy_pass         http://127.0.0.1:8088;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;    # async-query websocket
        proxy_set_header   Connection        \$ws_connection;
    }
}
NGINX

nginx -t && nginx -s reload
echo "superset BI vhost configured at https://bi.$STAGING_DOMAIN (inert until :8088 up)"

# ── oauth2-proxy vhost (auth.<domain>) ────────────────────────────────────────
# NO origin-verify + NO auth_request — this IS the authentication endpoint.
# Serves ONLY the /oauth2/ callback+start+sign_out endpoints; everything else 404.
cat > /etc/nginx/conf.d/auth.conf <<NGINX
server {
    listen 80;
    server_name auth.$STAGING_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name auth.$STAGING_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # oauth2-proxy (Cognito) — callback + start + sign_out (ADR-0034 §C).
    # Authentik retired; this vhost now serves ONLY the oauth2 endpoints.
    location /oauth2/ {
        proxy_pass              http://127.0.0.1:4180;
        proxy_set_header        Host              \$host;
        proxy_set_header        X-Real-IP         \$remote_addr;
        proxy_set_header        X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        proxy_set_header        X-Forwarded-Host  \$host;
        proxy_buffer_size       32k;
        proxy_buffers           8 32k;
        proxy_busy_buffers_size 32k;
    }

    location / { return 404; }
}
NGINX

nginx -t && nginx -s reload
echo "oauth2-proxy SSO vhost configured at https://auth.$STAGING_DOMAIN"

# ── CPACK agent ingest front-door (ADR-0042 P1 — deliberately open) ────────────
# Public HTTPS front-door for CPACK's Node-RED tee → sparkplug-agent-cpack. TLS
# terminates on a dedicated port (8447) and reverse-proxies ONLY the exact path
# /v1/tags to the agent's plaintext HTTP listener on packiot-net (compose static
# IP 172.18.0.38:9104). Auth is the agent's own X-Ingest-Key header — the same
# "no SSO" carve-out the /api/ vhost uses. Inbound 8447 is admitted for CPACK's
# egress /32 ONLY (security_groups.tf). Reuses the wildcard cert.
cat > /etc/nginx/conf.d/cpack-ingest.conf <<NGINX
server {
    listen 8447 ssl;
    server_name cpack-ingest.$STAGING_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 1m;   # matches the agent's MaxBodyBytes cap

    location = /v1/tags {
        proxy_pass         http://172.18.0.38:9104;   # sparkplug-agent-cpack
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 30s;
    }
}
NGINX

nginx -t && nginx -s reload
echo "CPACK agent ingest front-door configured at https://cpack-ingest.$STAGING_DOMAIN:8447/v1/tags"

# ── Auto-renew ────────────────────────────────────────────────────────────────
# AL2023 doesn't include cronie by default.
dnf install -y cronie
systemctl enable --now crond
echo "0 3 * * * root certbot renew --quiet && nginx -s reload" \
  > /etc/cron.d/certbot-renew

echo "=== Nginx + Certbot setup complete $(date -u) ==="
