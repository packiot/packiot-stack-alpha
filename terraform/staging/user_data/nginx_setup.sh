#!/bin/bash
# Installs and configures Nginx + Certbot (Let's Encrypt wildcard cert via Route53 DNS-01).
# Safe to run on a live EC2 — does NOT touch .env, Docker, or Node-RED. Idempotent.
#
# Access control: Nginx HTTP Basic Auth on all vhosts.
# Credentials fetched from AWS Secrets Manager at packiot/staging/nginx-auth.
set -euo pipefail
exec > >(tee /var/log/packiot-nginx-setup.log | logger -t packiot-nginx-setup) 2>&1

echo "=== Nginx + Certbot setup starting $(date -u) ==="

STAGING_DOMAIN="${staging_domain}"
AWS_REGION="${aws_region}"

# ── Nginx ─────────────────────────────────────────────────────────────────────
dnf install -y nginx
systemctl enable nginx

# ── Fetch nginx-auth credentials from Secrets Manager ────────────────────────
NGINX_AUTH=$(aws secretsmanager get-secret-value \
  --secret-id packiot/staging/nginx-auth \
  --region "$AWS_REGION" \
  --query SecretString --output text)
NGINX_USER=$(echo "$NGINX_AUTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
NGINX_PASS=$(echo "$NGINX_AUTH" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

printf '%s:%s\n' "$NGINX_USER" "$(openssl passwd -apr1 "$NGINX_PASS")" \
  > /etc/nginx/.htpasswd
chmod 600 /etc/nginx/.htpasswd
echo "htpasswd written for user: $NGINX_USER"

# ── Write HTTP vhosts (port 80) — temporary until cert is obtained ────────────
%{ for svc, port in services ~}
cat > /etc/nginx/conf.d/${svc}.conf <<NGINX
server {
    listen 80;
    server_name ${svc}.$STAGING_DOMAIN;

    location / {
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
NGINX
%{ endfor ~}

nginx -t && systemctl start nginx
echo "Nginx HTTP vhosts configured"

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

# ── Rewrite vhosts: HTTP redirect + HTTPS with basic auth ────────────────────
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
echo "HTTPS with basic auth configured for all services"

# ── Auto-renew ────────────────────────────────────────────────────────────────
# AL2023 doesn't include cronie by default.
dnf install -y cronie
systemctl enable --now crond
echo "0 3 * * * root certbot renew --quiet && nginx -s reload" \
  > /etc/cron.d/certbot-renew

echo "=== Nginx + Certbot setup complete $(date -u) ==="
