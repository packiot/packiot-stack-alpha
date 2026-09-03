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

    # B4 (2026-08-12): Cognito oauth2 outer gate REMOVED. operator is a factory
    # kiosk with its OWN /session login (operator_pw_hash + JWT_SECRET — see
    # edge-api login.service.ts). That local auth is the sole gate; CloudFront +
    # WAF + origin-verify (above) remain the edge protection. Floor operators are
    # provisioned as operator-DB users (operator_pw_hash) via CS Admin, NOT in the
    # Cognito pool — so the outer Cognito gate would 302 them to a login they have
    # no account for (the "blue Cognito page" go-live blocker).
    location / {
        proxy_pass         http://127.0.0.1:8083;
        proxy_set_header   Host                 \$host;
        proxy_set_header   X-Real-IP            \$remote_addr;
        proxy_set_header   X-Forwarded-For      \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto    https;
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
# certificate (HTTP-01 webroot, NOT the *.$PRODUCTION_DOMAIN wildcard). Its cert
# is provisioned out-of-band; write the vhost only if the cert already exists so a
# fresh boot never fails `nginx -t` on a missing cert (chicken-and-egg HTTP-01).
#
# SECURITY (2026-08): dash is now oauth2-gated (cs-admin group) — same Cognito
# forward-auth as the internal admin UIs. Previously it was UNGATED (open to
# anyone who reached it via CloudFront). The auth_request runs before try_files,
# so an unauthenticated hit gets 401 → @oauth2_signin → auth.$PRODUCTION_DOMAIN.
# The acme-challenge + http→https redirect on :80 stay UNGATED so certbot renewal
# never 302s to login.
# ⚠ COOKIE DOMAIN: this gate only works if oauth2-proxy's OAUTH2_PROXY_COOKIE_DOMAINS
# + OAUTH2_PROXY_WHITELIST_DOMAINS include `.packiot.app` (dash is on the apex, NOT
# *.prod.packiot.app). See compose.production.yml — must land together with this.
# ── dash static content (codified 2026-09-03) ──────────────────────────
# The service-directory page at dash.packiot.app. Was a hand-placed /var/www/dash/
# index.html that drifted (dead Hasura links + pre-rename service names). Codified
# here so nginx_setup.sh reproduces it; written unconditionally because the
# acme-challenge webroot below is /var/www/dash (dir must exist before the cert).
mkdir -p /var/www/dash
cat > /var/www/dash/index.html <<'DASHHTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Packiot — Service Dashboard</title>
<style>
  :root{
    --bg:#0f1115; --panel:#171a21; --panel2:#1e222b; --border:#282d38;
    --text:#e7eaf0; --muted:#9aa3b2; --accent:#4f8cff; --ok:#37b26b; --warn:#e0a53b;
    --int:#7c86f0;
  }
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--text);
    font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
  header{padding:28px 32px 18px;border-bottom:1px solid var(--border);
    display:flex;align-items:baseline;gap:14px;flex-wrap:wrap}
  header h1{margin:0;font-size:22px;font-weight:800;letter-spacing:-.02em}
  header .sub{color:var(--muted);font-size:13.5px}
  .wrap{max-width:1180px;margin:0 auto;padding:24px 32px 60px}
  .env{margin-top:30px}
  .env h2{display:flex;align-items:center;gap:10px;margin:0 0 4px;font-size:18px;font-weight:800}
  .badge{font-size:11px;font-weight:700;padding:2px 9px;border-radius:999px;text-transform:uppercase;letter-spacing:.04em}
  .b-prod{background:rgba(55,178,107,.15);color:var(--ok);border:1px solid rgba(55,178,107,.3)}
  .b-stg{background:rgba(224,165,59,.14);color:var(--warn);border:1px solid rgba(224,165,59,.3)}
  .b-dev{background:rgba(124,134,240,.14);color:var(--int);border:1px solid rgba(124,134,240,.3)}
  .env .dom{color:var(--muted);font-size:13px;margin:2px 0 16px}
  .env .dom code{color:var(--text);background:var(--panel2);padding:1px 6px;border-radius:5px}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(232px,1fr));gap:12px}
  .card{background:var(--panel);border:1px solid var(--border);border-radius:11px;
    padding:14px 15px;text-decoration:none;color:inherit;display:block;transition:.12s}
  a.card:hover{border-color:var(--accent);background:var(--panel2);transform:translateY(-1px)}
  .card .name{font-weight:700;font-size:14.5px;display:flex;align-items:center;gap:7px}
  .card .name .dot{width:7px;height:7px;border-radius:50%;background:var(--ok);flex:0 0 auto}
  .card .desc{color:var(--muted);font-size:12.5px;margin-top:4px}
  .card .url{color:var(--accent);font-size:12px;margin-top:8px;word-break:break-all;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
  .sect-label{margin:20px 0 9px;font-size:11.5px;font-weight:700;text-transform:uppercase;
    letter-spacing:.06em;color:var(--muted)}
  .infra{display:flex;flex-wrap:wrap;gap:8px}
  .chip{background:var(--panel);border:1px solid var(--border);border-radius:8px;
    padding:7px 11px;font-size:12.5px;display:flex;align-items:center;gap:7px}
  .chip .dot{width:6px;height:6px;border-radius:50%;background:var(--int)}
  .chip b{font-weight:650}
  .chip span{color:var(--muted)}
  .note{color:var(--muted);font-size:13px;background:var(--panel);border:1px solid var(--border);
    border-radius:9px;padding:12px 14px;margin-top:12px}
  footer{color:var(--muted);font-size:12px;text-align:center;padding:26px 0 8px;border-top:1px solid var(--border);margin-top:44px}
  .legend{display:flex;gap:16px;flex-wrap:wrap;color:var(--muted);font-size:12.5px;margin-top:6px}
  .legend span{display:flex;align-items:center;gap:6px}
  .lg-web{width:8px;height:8px;border-radius:50%;background:var(--ok)}
  .lg-int{width:8px;height:8px;border-radius:50%;background:var(--int)}
</style>
</head>
<body>
<header>
  <h1>Packiot · Service Dashboard</h1>
  <span class="sub">All services, by environment</span>
</header>
<div class="wrap">
  <div class="legend">
    <span><i class="lg-web"></i> Web UI (clickable, behind SSO)</span>
    <span><i class="lg-int"></i> Internal service (no public vhost)</span>
  </div>

  <!-- PRODUCTION -->
  <section class="env">
    <h2>Production <span class="badge b-prod">live</span></h2>
    <div class="dom">Web services at <code>&lt;service&gt;.prod.packiot.app</code> · new-prod stack (F3-native) · behind CloudFront + WAF + Cognito SSO</div>
    <div class="grid">
      <a class="card" href="https://csadmin.prod.packiot.app" target="_blank"><div class="name"><i class="dot"></i>CS Admin</div><div class="desc">Client onboarding + edge deploy button</div><div class="url">csadmin.prod.packiot.app</div></a>
      <a class="card" href="https://grafana.prod.packiot.app" target="_blank"><div class="name"><i class="dot"></i>Grafana</div><div class="desc">OEE dashboards + observability</div><div class="url">grafana.prod.packiot.app</div></a>
      <a class="card" href="https://operator.prod.packiot.app" target="_blank"><div class="name"><i class="dot"></i>Operator</div><div class="desc">Operator UI (PO control, downtimes)</div><div class="url">operator.prod.packiot.app</div></a>
      <a class="card" href="https://api.prod.packiot.app" target="_blank"><div class="name"><i class="dot"></i>edge-api</div><div class="desc">Control plane / write plane (NestJS)</div><div class="url">api.prod.packiot.app</div></a>
      <a class="card" href="https://adminer.prod.packiot.app" target="_blank"><div class="name"><i class="dot"></i>Adminer</div><div class="desc">Postgres admin</div><div class="url">adminer.prod.packiot.app</div></a>
      <a class="card" href="https://rabbitmq.prod.packiot.app" target="_blank"><div class="name"><i class="dot"></i>RabbitMQ</div><div class="desc">Broker management UI</div><div class="url">rabbitmq.prod.packiot.app</div></a>
    </div>
    <div class="sect-label">Infrastructure &amp; data plane (internal)</div>
    <div class="infra">
      <div class="chip"><i class="dot"></i><b>sparkplug-decoder</b><span>SparkPlug decode · Calc · fmr edge-transformer</span></div>
      <div class="chip"><i class="dot"></i><b>refdata-api</b><span>read plane</span></div>
      <div class="chip"><i class="dot"></i><b>stream-engine</b><span>OEE compute · fmr oeecloud-worker</span></div>
      <div class="chip"><i class="dot"></i><b>mosquitto</b><span>:8883 mTLS MQTT ingest (primary)</span></div>
      <div class="chip"><i class="dot"></i><b>ingest-shim · operator-adapter</b><span>legacy HTTP ingest (ports retired, internal only)</span></div>
      <div class="chip"><i class="dot"></i><b>pgbouncer → TimescaleDB</b><span>database</span></div>
      <div class="chip"><i class="dot"></i><b>app-redis</b><span>cache</span></div>
      <div class="chip"><i class="dot"></i><b>oauth2-proxy</b><span>Cognito SSO gate (:4180)</span></div>
      <div class="chip"><i class="dot"></i><b>prometheus · loki · promtail</b><span>metrics + logs</span></div>
    </div>
  </section>

  <!-- STAGING -->
  <section class="env">
    <h2>Staging <span class="badge b-stg">test</span></h2>
    <div class="dom">Web services at <code>&lt;service&gt;.staging.packiot.app</code> · behind CloudFront + WAF + Cognito SSO</div>
    <div class="grid">
      <a class="card" href="https://grafana.staging.packiot.app" target="_blank"><div class="name"><i class="dot"></i>Grafana</div><div class="desc">OEE dashboards + observability</div><div class="url">grafana.staging.packiot.app</div></a>
      <a class="card" href="https://operator.staging.packiot.app" target="_blank"><div class="name"><i class="dot"></i>Operator</div><div class="desc">Operator UI</div><div class="url">operator.staging.packiot.app</div></a>
      <a class="card" href="https://api.staging.packiot.app" target="_blank"><div class="name"><i class="dot"></i>edge-api</div><div class="desc">Control plane API</div><div class="url">api.staging.packiot.app</div></a>
      <a class="card" href="https://adminer.staging.packiot.app" target="_blank"><div class="name"><i class="dot"></i>Adminer</div><div class="desc">Postgres admin</div><div class="url">adminer.staging.packiot.app</div></a>
      <a class="card" href="https://rabbitmq.staging.packiot.app" target="_blank"><div class="name"><i class="dot"></i>RabbitMQ</div><div class="desc">Broker management UI</div><div class="url">rabbitmq.staging.packiot.app</div></a>
    </div>
    <div class="note"><b>Legacy / retiring:</b> <code>oeecloud-nodered</code> (the old cloud OEE engine) is
      <b>decommissioned</b> — OEE now runs in the Go worker <code>stream-engine</code> (F3 flow), not Node-RED;
      <code>sparkplug-decoder</code> does the SparkPlug decode + Calc one hop upstream.
      <code>edge-nodered</code> (factory low-code, :1880) still runs on staging but is superseded by the
      config-as-data <code>sparkplug-agent</code> + generated reader flow; it is not deployed on production.</div>
    <div class="sect-label">Infrastructure &amp; data plane (internal)</div>
    <div class="infra">
      <div class="chip"><i class="dot"></i><b>sparkplug-decoder</b><span>SparkPlug decode · Calc · fmr edge-transformer</span></div>
      <div class="chip"><i class="dot"></i><b>refdata-api</b><span>read plane</span></div>
      <div class="chip"><i class="dot"></i><b>stream-engine</b><span>OEE compute · fmr oeecloud-worker</span></div>
      <div class="chip"><i class="dot"></i><b>ingest-shim · operator-adapter</b><span>ingest tees</span></div>
      <div class="chip"><i class="dot"></i><b>mosquitto</b><span>MQTT bus</span></div>
      <div class="chip"><i class="dot"></i><b>pgbouncer → TimescaleDB</b><span>database</span></div>
      <div class="chip"><i class="dot"></i><b>oauth2-proxy</b><span>Cognito SSO gate</span></div>
      <div class="chip"><i class="dot"></i><b>prometheus · loki</b><span>observability</span></div>
    </div>
  </section>

  <!-- DEVELOPMENT -->
  <section class="env">
    <h2>Development <span class="badge b-dev">branch</span></h2>
    <div class="dom">Integration branch — <code>compose.development.yml</code></div>
    <div class="note">The <code>development</code> branch is now synced to the same git HEAD as staging &amp; production.
      There is no standing <code>*.dev.packiot.app</code> deployment; development runs locally via
      <code>docker compose -f compose.development.yml up</code> (same service set as staging).</div>
  </section>

  <footer>Packiot service directory · built for quick navigation across environments</footer>
</div>
</body>
</html>
DASHHTML

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

    # Cognito forward-auth (oauth2-proxy) — staff-only, same gate as admin UIs.
    include snippets/oauth2-proxy.conf;

    root /var/www/dash;
    index index.html;
    location / {
        auth_request /oauth2/auth-csadmin;
        auth_request_set \$auth_user  \$upstream_http_x_auth_request_user;
        auth_request_set \$auth_email \$upstream_http_x_auth_request_email;
        error_page 401 = @oauth2_signin;

        try_files \$uri \$uri/ /index.html;
    }
}
NGINX
nginx -t && nginx -s reload
echo "dash static SPA vhost configured at https://dash.packiot.app (oauth2-gated)"
else
echo "SKIP: /etc/letsencrypt/live/dash.packiot.app absent — dash vhost not written" \
     "(hand-managed HTTP-01 cert; obtain it then re-run this script)"
fi

# ── wiki vhost (internal docs SPA on the packiot.app apex — oauth2-gated) ──────
# wiki.packiot.app is an internal, staff-only static site served from /var/www/wiki.
# It is reached ONLY via CloudFront (edge.tf: cert SAN + alias + wiki_edge ALIAS).
# CloudFront dials the origin at origin.$PRODUCTION_DOMAIN, so the origin TLS
# handshake SNI is origin.$PRODUCTION_DOMAIN — covered by the *.$PRODUCTION_DOMAIN
# wildcard cert already obtained above. We therefore reuse that wildcard cert here
# (NOT a separate wiki.packiot.app cert like dash), so the vhost serves as soon as
# /var/www/wiki is populated — no extra out-of-band cert step. Host-header routing
# (server_name wiki.packiot.app) selects this block after TLS terminates.
#
# Protection = the same posture as the internal *.prod service vhosts:
#   * origin-verify (CloudFront-only; direct-to-EIP hits 403)
#   * oauth2-proxy cs-admin forward-auth (Cognito, staff-only)
# Content is owned by a separate markdown→HTML pipeline; this only creates the
# vhost + gate so /var/www/wiki serves once populated.
# ⚠ COOKIE DOMAIN: like dash, the gate only works if oauth2-proxy's
# OAUTH2_PROXY_COOKIE_DOMAINS + OAUTH2_PROXY_WHITELIST_DOMAINS include `.packiot.app`
# (wiki is on the apex, NOT *.prod.packiot.app) — see compose.production.yml.
cat > /etc/nginx/conf.d/wiki.conf <<NGINX
server {
    listen 80;
    server_name wiki.packiot.app;
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name wiki.packiot.app;
    ssl_certificate     /etc/letsencrypt/live/$PRODUCTION_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PRODUCTION_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    include snippets/origin-verify.conf;

    # Cognito forward-auth (oauth2-proxy) — staff-only, same gate as admin UIs.
    include snippets/oauth2-proxy.conf;

    root /var/www/wiki;
    index index.html;
    location / {
        auth_request /oauth2/auth-csadmin;
        auth_request_set \$auth_user  \$upstream_http_x_auth_request_user;
        auth_request_set \$auth_email \$upstream_http_x_auth_request_email;
        error_page 401 = @oauth2_signin;

        try_files \$uri \$uri/ /index.html;
    }
}
NGINX
nginx -t && nginx -s reload
echo "wiki internal vhost configured at https://wiki.packiot.app (oauth2-gated)"

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
