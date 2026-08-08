#!/bin/bash
# Production: Nginx + Certbot (Let's Encrypt wildcard cert via Route53 DNS-01).
# Safe to run on a live EC2 — does NOT touch .env, Docker, or services. Idempotent.
#
# Access control: oauth2-proxy (Cognito OIDC) via nginx auth_request forward-auth
# (ADR-0034 §C). Authentik is RETIRED. Two internal subrequest endpoints live in
# snippets/oauth2-proxy.conf (/oauth2/auth = any pool user; /oauth2/auth-csadmin =
# cs-admin group only). Every CloudFront-fronted vhost also includes
# snippets/origin-verify.conf, which 403s any request that did not enter via
# CloudFront (the X-Origin-Verify shared secret is fetched from Secrets Manager
# at runtime below — never hardcoded).
#
# Production variant of staging's nginx_setup.sh. Differences:
#   - PRODUCTION_DOMAIN (vs STAGING_DOMAIN)
#   - NO AMQPS stream proxy (production doesn't expose 5671 — no factory
#     broker here per security_groups.tf)
#   - refdata IS exposed (front4/operator read plane) but PROTECTED: origin-verify
#     (CloudFront-only) + refdata's own JWT/tenant-isolation + scoped CORS — NOT open
#   - NO deliberately-open staging-only vhosts (mq / cpack-ingest)
#   - NO node-red editor vhosts (edge-nodered / oeecloud-nodered are staging-only)
set -euo pipefail
exec > >(tee /var/log/packiot-nginx-setup.log | logger -t packiot-nginx-setup) 2>&1

echo "=== Nginx + Certbot setup starting $(date -u) ==="

PRODUCTION_DOMAIN="${production_domain}"
AWS_REGION="${aws_region}"

# ── X-Origin-Verify shared secret (edge origin-lock) ──────────────────────────
# Fetched at runtime from packiot/production/app (key x_origin_verify) using the
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
X_ORIGIN_VERIFY=$(get_secret "packiot/production/app" | jq -r '.x_origin_verify // ""')
if [ -z "$X_ORIGIN_VERIFY" ] || [ "$X_ORIGIN_VERIFY" = "null" ]; then
  echo "WARNING: packiot/production/app.x_origin_verify is empty — origin-verify" \
       "will 403 legitimate CloudFront traffic. Populate the secret + re-run."
fi

# ── Nginx ─────────────────────────────────────────────────────────────────────
dnf install -y nginx
systemctl enable nginx

# ── WebSocket connection map ───────────────────────────────────────────────────
# Sets $ws_connection = "upgrade" only when the client sends an Upgrade header.
# For plain HTTP requests, $ws_connection = "close". Avoids sending
# Connection: upgrade on non-WebSocket requests, which confuses Grafana's
# Go HTTP server and causes 500 errors.
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
  --domain "*.$PRODUCTION_DOMAIN" \
  --domain "$PRODUCTION_DOMAIN" \
  --email ops@packiot.com \
  --agree-tos \
  --non-interactive \
  --logs-dir /var/log/letsencrypt

if [ ! -d "/etc/letsencrypt/live/$PRODUCTION_DOMAIN" ]; then
  echo "ERROR: certbot did not produce a cert — check /var/log/letsencrypt"
  exit 1
fi
echo "Certificate obtained: /etc/letsencrypt/live/$PRODUCTION_DOMAIN"

# ── Shared snippet: oauth2-proxy forward-auth ─────────────────────────────────
cat > /etc/nginx/snippets/oauth2-proxy.conf <<NGINX
# oauth2-proxy (Cognito) forward-auth — shared include (ADR-0034 §C).
# /oauth2/ callback+start live on auth.$PRODUCTION_DOMAIN. nginx auth_request no-ops with a
# query string, so group filters are baked into proxy_pass as two internal
# endpoints. Per protected location add:
#   auth_request /oauth2/auth;           # any authenticated pool user (operator)
#   auth_request /oauth2/auth-csadmin;   # staff-only (admin UIs)
# plus: error_page 401 = @oauth2_signin;   (403 wrong-group falls through)
location = /oauth2/auth {
    internal;
    proxy_pass http://127.0.0.1:4180/oauth2/auth;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Uri \$request_uri;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_buffer_size 32k; proxy_buffers 8 32k; proxy_busy_buffers_size 32k;
}
location = /oauth2/auth-csadmin {
    internal;
    proxy_pass http://127.0.0.1:4180/oauth2/auth?allowed_groups=cs-admin;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Uri \$request_uri;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_buffer_size 32k; proxy_buffers 8 32k; proxy_busy_buffers_size 32k;
}
location @oauth2_signin {
    return 302 https://auth.$PRODUCTION_DOMAIN/oauth2/start?rd=\$scheme://\$http_host\$request_uri;
}
NGINX

# ── Shared snippet: X-Origin-Verify origin-lock ───────────────────────────────
cat > /etc/nginx/snippets/origin-verify.conf <<NGINX
# ADR edge origin-lock (step c): reject anything that did not enter via CloudFront.
# CloudFront stamps X-Origin-Verify on every origin request; direct-to-EIP lacks
# it -> 403. Included ONLY in CloudFront-fronted vhosts (NOT auth/ingest/dash).
if (\$http_x_origin_verify != "$X_ORIGIN_VERIFY") {
    return 403;
}
NGINX

# ── Buffer bump for large Cognito cookies ─────────────────────────────────────
cat > /etc/nginx/conf.d/00-oauth2-buffers.conf <<NGINX
# ADR-0034 §C — Cognito tokens make the oauth2-proxy session cookie exceed 4kb,
# split across _oauth2_proxy_N cookies sent domain-wide. Raise the header buffer.
large_client_header_buffers 8 32k;
NGINX

# ── Staff-tier vhosts (cs-admin group forward-auth) ───────────────────────────
# Generated for every service whose auth tier is "csadmin". The bespoke tiers
# (api / operator / csadmin-SPA) are emitted as explicit blocks below and are
# deliberately skipped by this loop; the deliberately-open + auth + dash vhosts
# are handled separately too.
%{ for svc, port in services ~}
%{ if lookup(service_auth, svc, "csadmin") == "csadmin" ~}
cat > /etc/nginx/conf.d/${svc}.conf <<NGINX
server {
    listen 80;
    server_name ${svc}.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${svc}.$PRODUCTION_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
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
# AuthMiddleware enforces x-api-key there — a browser 302 login would break
# machine clients / the prod nginx mirror / factory edges).
cat > /etc/nginx/conf.d/api.conf <<NGINX
server {
    listen 80;
    server_name api.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name api.$PRODUCTION_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;

    include snippets/oauth2-proxy.conf;

    # edge-api's AuthMiddleware enforces x-api-key auth on /api/*, so the gateway
    # gate is redundant here — bypass it (unchanged from the Authentik setup).
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

# ── operator vhost (any authenticated pool user) ──────────────────────────────
cat > /etc/nginx/conf.d/operator.conf <<NGINX
server {
    listen 80;
    server_name operator.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name operator.$PRODUCTION_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;

    # Cognito forward-auth (oauth2-proxy) — replaces Authentik. operator serves
    # client factory users, so it gates on ANY authenticated pool user (not
    # cs-admin). Client logins are provisioned via CS Admin.
    include snippets/oauth2-proxy.conf;

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
# csadmin.$PRODUCTION_DOMAIN — CS-Admin SPA. DEMO: no Authentik layer (csadmin has
# its own Firebase login as the gate). FOLLOW-UP: register csadmin as an Authentik
# application + restore the forward-auth block (see operator.conf) for prod SSO.
server {
    listen 80;
    server_name csadmin.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name csadmin.$PRODUCTION_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
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

# ── refdata vhost (refdata-api F3 read plane — front4/operator SPAs) ───────────
# refdata.$PRODUCTION_DOMAIN. origin-verify (CloudFront-only) + refdata's OWN JWT +
# tenant-isolation (#57/#68). NO oauth2 (Bearer, not cookie). CORS scoped to the
# front/operator SPA origins. Proxies refdata-api's static compose IP 172.18.0.26:9104
# (tidier-consistency option: publish a 127.0.0.1 host port like api/csadmin).
cat > /etc/nginx/conf.d/refdata.conf <<NGINX
map \$http_origin \$refdata_cors {
    default "";
    "~^https://(front|operator)\.$PRODUCTION_DOMAIN\$" \$http_origin;
}
server {
    listen 80;
    server_name refdata.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name refdata.$PRODUCTION_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;
    location / {
        if (\$request_method = OPTIONS) {
            add_header Access-Control-Allow-Origin  \$refdata_cors always;
            add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
            add_header Access-Control-Max-Age 86400 always;
            add_header Vary Origin always;
            return 204;
        }
        add_header Access-Control-Allow-Origin  \$refdata_cors always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
        add_header Vary Origin always;
        proxy_pass         http://172.18.0.26:9104;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_http_version 1.1;
    }
}
NGINX

# ── superset vhost (W2 self-service BI — embedded in front4) ───────────────────
# bi.$PRODUCTION_DOMAIN. Modeled on the refdata block: origin-verify (CloudFront-
# only) + scoped CORS. DIFFERENCES vs refdata (both load-bearing for embedding):
#   * Superset has its OWN auth — short-lived guest tokens for embedded VIEWING
#     (minted by edge-api) and a Cognito-OIDC session for AUTHORING — so it does
#     NOT sit behind oauth2-proxy (a cookie forward-auth would break the iframe
#     handshake AND the OIDC redirect). No auth_request here.
#   * It MUST be iframe-embeddable: Superset's Talisman emits
#     `Content-Security-Policy: frame-ancestors https://front.$PRODUCTION_DOMAIN`
#     (superset_config.py). We MUST NOT add X-Frame-Options (no per-origin allow;
#     it would blank the iframe).
#   * WebSocket upgrade is wired for Superset's async-query progress channel.
# The wildcard cert (*.$PRODUCTION_DOMAIN) already covers bi.$PRODUCTION_DOMAIN.
# Go-live still needs the Route53 record + CloudFront alias/origin-verify behavior
# (docs/plans/w2-embedded-superset.md §1.4/§6). DNS is NOT applied here; the vhost
# is inert until superset (:8088) is up.
cat > /etc/nginx/conf.d/superset.conf <<NGINX
map \$http_origin \$superset_cors {
    default "";
    "~^https://front\.$PRODUCTION_DOMAIN\$" \$http_origin;
}
server {
    listen 80;
    server_name bi.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name bi.$PRODUCTION_DOMAIN;
    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
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
echo "oauth2-proxy forward-auth + origin-verify configured for all services"

# ── oauth2-proxy vhost (auth.<domain>) ────────────────────────────────────────
# NO origin-verify + NO auth_request — this IS the authentication endpoint.
# Serves ONLY the /oauth2/ callback+start+sign_out endpoints; everything else 404.
cat > /etc/nginx/conf.d/auth.conf <<NGINX
server {
    listen 80;
    server_name auth.$PRODUCTION_DOMAIN;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name auth.$PRODUCTION_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
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
echo "oauth2-proxy SSO vhost configured at https://auth.$PRODUCTION_DOMAIN"

# ── dash vhost (static SPA on the packiot.app apex — hand-managed cert) ────────
# dash.packiot.app is a static SPA served from /var/www/dash on a SEPARATE
# certificate (HTTP-01 webroot, NOT the *.$PRODUCTION_DOMAIN wildcard). No auth,
# no origin-verify — untouched by the oauth2 posture. Its cert is provisioned
# out-of-band; write the vhost only if the cert already exists so a fresh boot
# never fails `nginx -t` on a missing cert (chicken-and-egg with HTTP-01).
if [ -d /etc/letsencrypt/live/dash.packiot.app ]; then
cat > /etc/nginx/conf.d/dash.conf <<NGINX
server {
    listen 80;
    server_name dash.packiot.app;
    location /.well-known/acme-challenge/ { root /var/www/dash; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl;
    server_name dash.packiot.app;
    ssl_certificate     /etc/letsencrypt/live/dash.packiot.app/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dash.packiot.app/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    root /var/www/dash;
    index index.html;
    location / { try_files \$uri \$uri/ /index.html; }
}
NGINX
nginx -t && nginx -s reload
echo "dash static SPA vhost configured at https://dash.packiot.app"
else
echo "SKIP: /etc/letsencrypt/live/dash.packiot.app absent — dash vhost not written" \
     "(hand-managed HTTP-01 cert; obtain it then re-run this script)"
fi

# NOTE: Staging's AMQPS stream proxy (port 5671), RabbitMQ mgmt (mq.<domain>),
# refdata + cpack-ingest carve-outs, and node-red editor vhosts are DELIBERATELY
# ABSENT from production. Production doesn't expose a broker to factory edges nor
# run Node-RED in this stack. If/when that changes, port the matching blocks from
# staging's nginx_setup.sh + add the ingress rules to security_groups.tf.

# ── Auto-renew ────────────────────────────────────────────────────────────────
# AL2023 doesn't include cronie by default.
dnf install -y cronie
systemctl enable --now crond
echo "0 3 * * * root certbot renew --quiet && nginx -s reload" \
  > /etc/cron.d/certbot-renew

echo "=== Nginx + Certbot setup complete $(date -u) ==="
