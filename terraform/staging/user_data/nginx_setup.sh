#!/bin/bash
# Installs and configures Nginx + Certbot (Let's Encrypt wildcard cert via Route53 DNS-01).
# Safe to run on a live EC2 — does NOT touch .env, Docker, or Node-RED. Idempotent.
#
# Security layers applied here:
#   1. Nginx basic auth   — all vhosts require credentials from packiot/staging/nginx-auth
#   2. CloudFront secret  — Nginx rejects requests missing X-CloudFront-Secret header;
#                           only CloudFront knows the value (packiot/staging/cloudfront-secret)
#
# Port 80 serves content directly — this is the CloudFront HTTP origin endpoint.
# Port 443 serves with TLS — kept for future direct-access use; currently unreachable
#   from the internet because the security group restricts port 80 to CloudFront only
#   and port 443 is not open at all.
set -euo pipefail
exec > >(tee /var/log/packiot-nginx-setup.log | logger -t packiot-nginx-setup) 2>&1

echo "=== Nginx + Certbot setup starting $(date -u) ==="

STAGING_DOMAIN="${staging_domain}"
AWS_REGION="${aws_region}"

# ── Nginx ─────────────────────────────────────────────────────────────────────
dnf install -y nginx
systemctl enable nginx

# ── Fetch credentials from Secrets Manager ────────────────────────────────────
NGINX_AUTH=$(aws secretsmanager get-secret-value \
  --secret-id packiot/staging/nginx-auth \
  --region "$AWS_REGION" \
  --query SecretString --output text)
NGINX_USER=$(echo "$NGINX_AUTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
NGINX_PASS=$(echo "$NGINX_AUTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

CF_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id packiot/staging/cloudfront-secret \
  --region "$AWS_REGION" \
  --query SecretString --output text)

# ── htpasswd (APR1-MD5, natively supported by nginx) ─────────────────────────
printf '%s:%s\n' "$NGINX_USER" "$(openssl passwd -apr1 "$NGINX_PASS")" \
  > /etc/nginx/.htpasswd
chmod 600 /etc/nginx/.htpasswd
echo "htpasswd written for user: $NGINX_USER"

# ── CloudFront secret map (http context — loaded before server blocks) ────────
# Requests without the correct X-CloudFront-Secret header get 403.
# Defense-in-depth: security group already restricts port 80 to CloudFront IPs.
cat > /etc/nginx/conf.d/00-cloudfront-auth.conf <<NGINX
map \$http_x_cloudfront_secret \$cf_authorized {
    "$CF_SECRET" 1;
    default      0;
}
NGINX
echo "CloudFront secret map written"

# ── HTTP vhosts (port 80) — CloudFront origin endpoint ───────────────────────
# NO redirect to HTTPS here. CloudFront hits port 80 directly, enforces HTTPS
# for viewers via viewer_protocol_policy = "redirect-to-https".
%{ for svc, port in services ~}
cat > /etc/nginx/conf.d/${svc}.conf <<NGINX
server {
    listen 80;
    server_name ${svc}.$STAGING_DOMAIN;

    location / {
        if (\$cf_authorized = 0) {
            return 403;
        }
        auth_basic           "Packiot Staging";
        auth_basic_user_file /etc/nginx/.htpasswd;

        proxy_pass         http://127.0.0.1:${port};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;

        # WebSocket support (Node-RED, Grafana live panels)
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
NGINX
%{ endfor ~}

nginx -t && systemctl start nginx
echo "Nginx HTTP vhosts configured"

# ── Certbot + Let's Encrypt (DNS-01 via Route53) ──────────────────────────────
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

# ── HTTPS vhosts (port 443) — emergency direct access / future use ────────────
# Port 443 is NOT open in the security group (CloudFront uses port 80 as origin).
# These vhosts are pre-configured so that direct access can be enabled by simply
# opening port 443 in the SG — no Nginx change needed.
%{ for svc, port in services ~}
cat > /etc/nginx/conf.d/${svc}.conf <<NGINX
server {
    listen 80;
    server_name ${svc}.$STAGING_DOMAIN;

    location / {
        if (\$cf_authorized = 0) {
            return 403;
        }
        auth_basic           "Packiot Staging";
        auth_basic_user_file /etc/nginx/.htpasswd;

        proxy_pass         http://127.0.0.1:${port};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;

        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
server {
    listen 443 ssl;
    server_name ${svc}.$STAGING_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$STAGING_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$STAGING_DOMAIN/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        auth_basic           "Packiot Staging";
        auth_basic_user_file /etc/nginx/.htpasswd;

        proxy_pass         http://127.0.0.1:${port};
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 300s;

        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
    }
}
NGINX
%{ endfor ~}

nginx -t && nginx -s reload
echo "HTTPS vhosts configured (port 443 unreachable until SG is opened)"

# ── Auto-renew ────────────────────────────────────────────────────────────────
dnf install -y cronie
systemctl enable --now crond
echo "0 3 * * * root certbot renew --quiet && nginx -s reload" \
  > /etc/cron.d/certbot-renew

echo "=== Nginx + Certbot setup complete $(date -u) ==="
