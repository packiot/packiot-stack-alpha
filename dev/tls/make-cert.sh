#!/bin/sh
# dev/tls/make-cert.sh — one self-signed TLS pair for the dev services that refuse plaintext (ingest-shim,
# operator-gateway). Staging mounts a real cert from the host (/opt/packiot/{ingest-shim,operator-adapter}/certs);
# dev mints a throwaway one into the `dev-tls` volume on first use. Never committed, never leaves the laptop.
# Runs in the rabbitmq image (Tier 0 already pulled it, and it ships /opt/openssl/bin/openssl), so no extra
# download and no network. Idempotent: an existing pair is kept.
set -eu
OUT=/certs
OPENSSL=${OPENSSL:-/opt/openssl/bin/openssl}
if [ -s "$OUT/tls.crt" ] && [ -s "$OUT/tls.key" ]; then
  echo "dev-tls: keeping existing pair in $OUT"; exit 0
fi
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 825 \
  -subj "/CN=packiot-dev" \
  -addext "subjectAltName=DNS:localhost,DNS:ingest-shim,DNS:operator-gateway,DNS:operator-adapter,IP:127.0.0.1" \
  -keyout "$OUT/tls.key" -out "$OUT/tls.crt" 2>/dev/null
# the services run distroless as nonroot (uid 65532): the dev key must be readable by them
chmod 0644 "$OUT/tls.key" "$OUT/tls.crt"
echo "dev-tls: minted a self-signed pair in $OUT"
