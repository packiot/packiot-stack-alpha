#!/usr/bin/env bash
# gen-mtls-certs.sh — issue the mTLS material for the ADR-0042 §6 SparkPlug uplink.
#
# ONE self-managed CA signs both sides:
#   • SERVER cert — presented by the cloud mosquitto on :8883. Its SAN MUST equal
#     the hostname the agent dials (the agent verifies it with Go's default
#     hostname check — uplink/tls.go sets RootCAs but no InsecureSkipVerify).
#   • CLIENT cert — presented by the factory-edge sparkplug-agent. CN=<tenant> is
#     the identity the broker keys its (future) per-tenant ACL on.
#
# OUTPUT (./mtls-out/ by default):
#   client-ca.pem                 the CA cert (public) — trusted by BOTH sides
#   server-cert.pem server-key.pem   → cloud mosquitto  /mosquitto/certs/
#   <tenant>-cert.pem <tenant>-key.pem → edge host CERTS_DIR as uplink-cert/key.pem
#
# The CA private key (ca-key.pem) stays OFFLINE — it is NOT deployed anywhere; it
# only signs. Store it (and all keys) in Secrets Manager, never in git.
#
# USAGE
#   TENANT=cpack SERVER_DNS=ingest.prod.packiot.app ./gen-mtls-certs.sh
set -euo pipefail

TENANT="${TENANT:?set TENANT (e.g. cpack) — becomes the client cert CN}"
SERVER_DNS="${SERVER_DNS:?set SERVER_DNS — the hostname the agent dials, e.g. ingest.prod.packiot.app}"
OUT="${OUT:-./mtls-out}"
DAYS="${DAYS:-1825}"          # 5y; rotate before expiry
mkdir -p "$OUT"; cd "$OUT"

echo "→ CA"
openssl genrsa -out ca-key.pem 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca-key.pem -sha256 -days "$DAYS" \
  -subj "/O=Packiot/CN=Packiot Edge Uplink CA" -out client-ca.pem

echo "→ server cert (SAN=${SERVER_DNS})"
openssl genrsa -out server-key.pem 4096 2>/dev/null
openssl req -new -key server-key.pem -subj "/O=Packiot/CN=${SERVER_DNS}" -out server.csr
openssl x509 -req -in server.csr -CA client-ca.pem -CAkey ca-key.pem -CAcreateserial \
  -days "$DAYS" -sha256 -out server-cert.pem \
  -extfile <(printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$SERVER_DNS")

echo "→ client cert (CN=${TENANT})"
openssl genrsa -out "${TENANT}-key.pem" 4096 2>/dev/null
openssl req -new -key "${TENANT}-key.pem" -subj "/O=Packiot/CN=${TENANT}" -out "${TENANT}.csr"
openssl x509 -req -in "${TENANT}.csr" -CA client-ca.pem -CAkey ca-key.pem -CAcreateserial \
  -days "$DAYS" -sha256 -out "${TENANT}-cert.pem" \
  -extfile <(printf 'extendedKeyUsage=clientAuth\n')

rm -f server.csr "${TENANT}.csr"
echo
echo "✅ issued in ${OUT}:"
echo "   client-ca.pem  (trust anchor, both sides)"
echo "   server-cert.pem/server-key.pem  → cloud mosquitto /mosquitto/certs/{server-cert,server-key}.pem + client-ca.pem"
echo "   ${TENANT}-cert.pem/${TENANT}-key.pem → edge host CERTS_DIR as uplink-cert.pem/uplink-key.pem (+ client-ca.pem as uplink-ca.pem)"
echo "   ca-key.pem = OFFLINE signing key — store in Secrets Manager, deploy NOWHERE."
echo
echo "verify chain:"
openssl verify -CAfile client-ca.pem server-cert.pem "${TENANT}-cert.pem"
