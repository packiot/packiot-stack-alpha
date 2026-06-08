#!/bin/bash
# Installs and configures Nginx + Certbot (Let's Encrypt wildcard cert via Route53 DNS-01).
# Safe to run on a live EC2 — does NOT touch .env, Docker, or Node-RED. Idempotent.
#
# Access control: Authentik SSO via Nginx auth_request (forward auth).
# The Authentik server embedded outpost handles /outpost.goauthentik.io/auth/nginx
# subrequests. Unauthenticated browsers are redirected to auth.<domain>/...
set -euo pipefail
exec > >(tee /var/log/packiot-nginx-setup.log | logger -t packiot-nginx-setup) 2>&1

echo "=== Nginx + Certbot setup starting $(date -u) ==="

STAGING_DOMAIN="${staging_domain}"
AWS_REGION="${aws_region}"

# ── Nginx ─────────────────────────────────────────────────────────────────────
dnf install -y nginx
systemctl enable nginx

# (Basic auth removed — Authentik forward auth handles all service vhosts.)

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

# ── Write vhosts: HTTP redirect + HTTPS with Authentik forward auth ───────────
%{ for svc, port in services ~}
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

    # Redirect unauthenticated requests to Authentik login
    error_page 401 = @authentik_login;
    location @authentik_login {
        return 302 https://auth.$STAGING_DOMAIN/outpost.goauthentik.io/start?rd=\$scheme://\$http_host\$request_uri;
    }

    # Authentik embedded outpost — internal subrequest endpoint
    location /outpost.goauthentik.io {
        internal;
        proxy_pass              http://127.0.0.1:9000/outpost.goauthentik.io;
        proxy_pass_request_body off;
        proxy_set_header        Content-Length    "";
        proxy_set_header        X-Original-URL    \$scheme://\$http_host\$request_uri;
        proxy_set_header        X-Real-IP         \$remote_addr;
        proxy_set_header        X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header        X-Forwarded-Proto \$scheme;
        proxy_set_header        X-Forwarded-Host  \$http_host;
        proxy_set_header        Host              auth.$STAGING_DOMAIN;
    }

    location / {
        auth_request /outpost.goauthentik.io/auth/nginx;
        auth_request_set \$authentik_set_cookie \$upstream_http_set_cookie;
        add_header Set-Cookie \$authentik_set_cookie;
        error_page 401 = @authentik_login;

        proxy_pass         http://127.0.0.1:${port};
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
%{ endfor ~}

nginx -t && nginx -s reload
echo "HTTPS with Authentik forward auth configured for all services"

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

# ── RabbitMQ management API HTTPS proxy ──────────────────────────────────────
# Exposed as mq.$STAGING_DOMAIN → 127.0.0.1:15672.
# No nginx basic auth — RabbitMQ management plugin authenticates with its own
# user/password. The edge-client user (tags: management) can call the HTTP
# publish API from factory edges that don't have amqplib.
# Idempotent: guard prevents duplicate vhost on re-runs.
if ! grep -q "mq.$STAGING_DOMAIN" /etc/nginx/conf.d/mq.conf 2>/dev/null; then
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
fi

nginx -t && nginx -s reload
echo "RabbitMQ management API proxy configured at https://mq.$STAGING_DOMAIN"

# ── Authentik login vhost ─────────────────────────────────────────────────────
# No auth_request here — this IS the authentication endpoint. Plain HTTPS proxy.
# Idempotent guard: rewrite on every run so config stays in sync with cert renewals.
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

    location / {
        proxy_pass         http://127.0.0.1:9000;
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
echo "Authentik SSO vhost configured at https://auth.$STAGING_DOMAIN"

# ── Auto-renew ────────────────────────────────────────────────────────────────
# AL2023 doesn't include cronie by default.
dnf install -y cronie
systemctl enable --now crond
echo "0 3 * * * root certbot renew --quiet && nginx -s reload" \
  > /etc/cron.d/certbot-renew

echo "=== Nginx + Certbot setup complete $(date -u) ==="
