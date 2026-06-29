#!/bin/bash
# Production: Nginx + Certbot (Let's Encrypt wildcard cert via Route53 DNS-01).
# Safe to run on a live EC2 — does NOT touch .env, Docker, or services. Idempotent.
#
# Production variant of staging's nginx_setup.sh. Differences:
#   - PRODUCTION_DOMAIN (vs STAGING_DOMAIN)
#   - NO AMQPS stream proxy (production doesn't expose 5671 — no factory
#     broker here per security_groups.tf)
#   - NO RabbitMQ management API vhost (same reason — no external clients)
#   - All other vhosts identical in shape, just different domain
set -euo pipefail
exec > >(tee /var/log/packiot-nginx-setup.log | logger -t packiot-nginx-setup) 2>&1

echo "=== Nginx + Certbot setup starting $(date -u) ==="

PRODUCTION_DOMAIN="${production_domain}"
AWS_REGION="${aws_region}"

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

# ── Write vhosts: HTTP redirect + HTTPS with Authentik forward auth ───────────
%{ for svc, port in services ~}
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

    # Redirect unauthenticated requests to Authentik login
    error_page 401 = @authentik_login;
    location @authentik_login {
        return 302 https://auth.$PRODUCTION_DOMAIN/outpost.goauthentik.io/start?rd=\$scheme://\$http_host\$request_uri;
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
        proxy_set_header        Host              auth.$PRODUCTION_DOMAIN;
    }

%{ if svc == "api" ~}
    # edge-api's AuthMiddleware enforces x-api-key auth on /api/*, so the
    # Authentik gate is redundant here. Same pattern as staging.
    location ~ ^/api/ {
        proxy_pass         http://127.0.0.1:${port};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;
    }
%{ endif ~}

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

# NOTE: Staging's AMQPS stream proxy (port 5671) is DELIBERATELY ABSENT from
# production. Production doesn't expose a broker to factory edges from this
# stack. If/when production starts accepting factory AMQP traffic, copy
# staging's `## AMQPS TCP proxy (Nginx stream module)` block, install
# nginx-mod-stream, and add the matching port 5671 ingress rule to
# security_groups.tf.
#
# Same for staging's RabbitMQ management API HTTPS proxy (`mq.<domain>`) —
# production doesn't expose this either. The RabbitMQ container runs inside
# the compose network and is reachable only from other compose services
# (oeecloud-worker etc.).

# ── Authentik login vhost ─────────────────────────────────────────────────────
# No auth_request here — this IS the authentication endpoint. Plain HTTPS proxy.
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
echo "Authentik SSO vhost configured at https://auth.$PRODUCTION_DOMAIN"

# ── Auto-renew ────────────────────────────────────────────────────────────────
# AL2023 doesn't include cronie by default.
dnf install -y cronie
systemctl enable --now crond
echo "0 3 * * * root certbot renew --quiet && nginx -s reload" \
  > /etc/cron.d/certbot-renew

echo "=== Nginx + Certbot setup complete $(date -u) ==="
