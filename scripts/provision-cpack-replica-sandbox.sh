#!/usr/bin/env bash
# provision-cpack-replica-sandbox.sh — turn the staging sandbox box into a FULL,
# REAL-IMAGE replica of the CPACK edge box, with the data path SEVERED at five
# layers so it can PROVABLY never write to real CPACK.
#
# It supersedes the public-image MOCK (scripts/provision-sandbox-edge-box.sh):
# instead of alpine/redis/vanilla-nodered it deploys the SAME images + topology a
# real client runs — sparkplug-agent + s7/modbus/opcua readers + PLC-capable
# Node-RED + mosquitto (docs/clients/sandbox-edge/compose.replica.yml) — but
# generated the SAME way any client bundle is (onboard-gen) and cut off from real
# CPACK (see the SEVERANCE section of the compose + README-severance.md).
#
# SAFE BY DEFAULT: it builds/generates/mints everything locally and STOPS before
# the box. It only touches the box when you pass DEPLOY=1 (the guard) — you run
# the deploy step yourself once you've reviewed the plan it prints.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────
#   # dry prep only (default): build images, generate bundle, mint certs, print plan
#   MI=mi-0114b66366e2d6613 S3_BUCKET=my-sandbox-bucket \
#       ./scripts/provision-cpack-replica-sandbox.sh
#
#   # actually deploy (fires the guarded `aws ssm send-command`):
#   MI=mi-0114b66366e2d6613 S3_BUCKET=my-sandbox-bucket DEPLOY=1 \
#       ./scripts/provision-cpack-replica-sandbox.sh
#
# ── ENV ───────────────────────────────────────────────────────────────────────
#   MI          (required) SSM managed-instance id of the sandbox box (ent 2000003)
#   S3_BUCKET   (required unless SKIP_IMAGES=1) private S3 bucket you can write; the
#               big images are uploaded here and handed to the box as PRESIGNED URLs
#               (the box needs NO AWS creds — the URL self-authenticates over HTTPS).
#   AWS_REGION  (default us-east-1)
#   ARCH        (default amd64) target box arch; set arm64 for an ARM gateway
#   DEPLOY      (default 0) set 1 to actually run the SSM deploy step
#   SKIP_IMAGES (default 0) set 1 to reuse images already on the box (no build/upload)
#   SKIP_BUILD  (default 0) set 1 to reuse already-saved local image tars in WORK/
#   PRESIGN_TTL (default 3600) presigned-URL lifetime in seconds
set -euo pipefail

# ── config ────────────────────────────────────────────────────────────────────
MI="${MI:?set MI=<managed-instance-id> (the sbxcpack box, enterprise 2000003)}"
REGION="${AWS_REGION:-us-east-1}"
ARCH="${ARCH:-amd64}"
DEPLOY="${DEPLOY:-0}"
SKIP_IMAGES="${SKIP_IMAGES:-0}"
SKIP_BUILD="${SKIP_BUILD:-0}"
PRESIGN_TTL="${PRESIGN_TTL:-3600}"
TENANT_SLUG="sbxcpack"
TENANT_UPPER="SBXCPACK"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
ED="$HERE/docs/clients/sandbox-edge"
DESC="$ED/${TENANT_SLUG}.descriptor.yaml"
ETSRC="$HERE/services/edge-transformer"          # Go module: agent + s7/modbus/opcua readers + onboard-gen
WORK="${WORK:-$HERE/.sbxcpack-replica-work}"      # local scratch (gitignored by you)
BUNDLE="$WORK/bundle"                              # the config bundle staged for the box

AGENT_IMG="packiot/sparkplug-agent:local"         # matches compose AGENT_IMAGE default
NODERED_IMG="packiot/nodered-reader:4.0"          # matches compose NODERED_IMAGE default

log(){ printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# ── phase 0: preflight ────────────────────────────────────────────────────────
log "phase 0 — preflight"
need docker; need openssl; need aws; need tar; need base64
[ -f "$DESC" ] || die "descriptor not found: $DESC"
rm -rf "$BUNDLE"; mkdir -p "$BUNDLE/$TENANT_SLUG" "$BUNDLE/certs" "$BUNDLE/mosquitto" "$WORK/images"

# ── phase 1: generate the bundle the SAME way any client bundle is generated ───
# This is the onboard-gen path (identical to .github/workflows/generate-client-bundle.yml
# step "Generate onboarding artifacts") — NOT hand-rolled. The only deviation from
# a real bundle is the CERT step (phase 2) and the severed descriptor inputs.
log "phase 1 — onboard-gen (profile + agent + register + tee)"
need go
( cd "$ETSRC" && go build -o "$WORK/onboard-gen" ./cmd/onboard-gen )
"$WORK/onboard-gen" --descriptor "$DESC" --out "$BUNDLE/$TENANT_SLUG/"
ls -l "$BUNDLE/$TENANT_SLUG/"
[ -f "$BUNDLE/$TENANT_SLUG/${TENANT_SLUG}-agent.yaml" ] || die "onboard-gen did not emit ${TENANT_SLUG}-agent.yaml"
# HARD severance assertion: the generated agent.yaml must NOT carry a real ingest
# uplink. Fail closed if a real host ever leaks into the descriptor.
if grep -qiE 'ingest\.prod|ingest\.staging|ssl://ingest|amazonaws\.com' "$BUNDLE/$TENANT_SLUG/${TENANT_SLUG}-agent.yaml"; then
  die "generated agent.yaml references a REAL ingest host — refusing (data path not severed). Fix $DESC."
fi
# NOTE (config-as-data reader model): onboard-gen on THIS branch (services/edge-transformer)
# emits the tee-model set. The Go-reader artifacts (${TENANT_SLUG}-client.yaml +
# ${TENANT_SLUG}-reader-flow.json) are produced by onboard-gen on branch
# feat/edge-ssm-register (services/sparkplug-decoder, descriptor needs a plc: block).
# If present, they are copied through; if absent, the reader containers self-retire
# (harmless on the sandbox) and the nodered tee profile carries the topology.
for extra in "${TENANT_SLUG}-client.yaml" "${TENANT_SLUG}-reader-flow.json"; do
  [ -f "$BUNDLE/$TENANT_SLUG/$extra" ] && echo "  (reader-model artifact present: $extra)" || true
done

# ── phase 2: mint the SANDBOX mTLS identity (SEVERANCE L3) ─────────────────────
# A THROWAWAY CA signs a CN=sbxcpack client cert. This is NOT the real
# packiot/<target>/edge-uplink-ca — so the real broker ACL would reject this
# identity even if the network sever (L1) and loopback uplink (L2) both failed.
log "phase 2 — mint throwaway sandbox CA + CN=sbxcpack client cert"
CADIR="$WORK/ca"; mkdir -p "$CADIR"
if [ ! -f "$CADIR/sandbox-ca.pem" ]; then
  openssl genrsa -out "$CADIR/sandbox-ca-key.pem" 4096 2>/dev/null
  openssl req -x509 -new -nodes -key "$CADIR/sandbox-ca-key.pem" -sha256 -days 365 \
    -subj "/O=Packiot-SANDBOX/CN=Packiot SANDBOX Edge CA (DO NOT TRUST)" -out "$CADIR/sandbox-ca.pem"
fi
openssl genrsa -out "$CADIR/${TENANT_SLUG}-key.pem" 4096 2>/dev/null
openssl req -new -key "$CADIR/${TENANT_SLUG}-key.pem" \
  -subj "/O=Packiot-SANDBOX/CN=${TENANT_SLUG}" -out "$CADIR/${TENANT_SLUG}.csr"
openssl x509 -req -in "$CADIR/${TENANT_SLUG}.csr" \
  -CA "$CADIR/sandbox-ca.pem" -CAkey "$CADIR/sandbox-ca-key.pem" -CAcreateserial \
  -days 365 -sha256 -out "$CADIR/${TENANT_SLUG}-cert.pem" \
  -extfile <(printf 'extendedKeyUsage=clientAuth\n') 2>/dev/null
# Assert the identity is the sandbox one, never the real client.
CN="$(openssl x509 -in "$CADIR/${TENANT_SLUG}-cert.pem" -noout -subject)"
echo "  minted cert subject: $CN"
echo "$CN" | grep -qi 'CN *= *cpack$' && die "cert CN is the REAL cpack — refusing"
echo "$CN" | grep -qi "CN *= *${TENANT_SLUG}" || die "cert CN is not ${TENANT_SLUG}"
cp "$CADIR/${TENANT_SLUG}-cert.pem" "$BUNDLE/certs/uplink-cert.pem"
cp "$CADIR/${TENANT_SLUG}-key.pem"  "$BUNDLE/certs/uplink-key.pem"
cp "$CADIR/sandbox-ca.pem"          "$BUNDLE/certs/uplink-ca.pem"
chmod 0644 "$BUNDLE/certs/uplink-cert.pem" "$BUNDLE/certs/uplink-ca.pem"
chmod 0640 "$BUNDLE/certs/uplink-key.pem"

# ── phase 3: assemble static assets + the severed .env ────────────────────────
log "phase 3 — assemble compose + mosquitto + .env"
cp "$ED/compose.replica.yml" "$BUNDLE/compose.replica.yml"
cp "$ED/mosquitto/mosquitto.conf" "$BUNDLE/mosquitto/mosquitto.conf"
INGEST_KEY="$(openssl rand -hex 32)"   # box-local nodered→agent :9104 secret
cat > "$BUNDLE/.env" <<ENV
# GENERATED by provision-cpack-replica-sandbox.sh — severed sandbox replica.
TENANT_SLUG=${TENANT_SLUG}
TENANT_UPPER=${TENANT_UPPER}
# Real CPACK edge = Node-RED reader → agent → SparkPlug (the productized Mode-B
# topology). It does NOT run the config-as-data Go reader trio (s7/modbus/opcua) —
# that model + its generated -client.yaml/-reader-flow.json land on branch
# feat/edge-ssm-register. onboard-gen on THIS branch emits only the tee/nodered
# profile, so we run nodered-only for a FAITHFUL replica and to avoid bind-mounting
# a missing client.yaml. Flip to "nodered,reader" once the reader-model artifacts
# are generated (feat/edge-ssm-register merged).
COMPOSE_PROFILES=nodered
AGENT_IMAGE=${AGENT_IMG}
NODERED_IMAGE=${NODERED_IMG}
AGENT_CONFIG_FILE=./${TENANT_SLUG}/${TENANT_SLUG}-agent.yaml
AGENT_PROFILE_FILE=./${TENANT_SLUG}/${TENANT_SLUG}-profile.yaml
CLIENT_CONFIG_FILE=./${TENANT_SLUG}/${TENANT_SLUG}-client.yaml
NODERED_READER_FLOW=./${TENANT_SLUG}/${TENANT_SLUG}-reader-flow.json
CERTS_DIR=./certs
AGENT_INGEST_API_KEY=${INGEST_KEY}
AGENT_HTTP_INGEST_ENABLED=true
# SEVERANCE L5 — never dial the cloud register DB.
AGENT_TAGMAP_FROM_REGISTER=false
AGENT_PARAM_DECOMPOSITION=false
AGENT_BIRTH_ALL_MAPPED=true
# SEVERANCE L4 — PLC hosts are RFC-5737 TEST-NET (non-routable; L1 blackholes too).
S7_HOST=192.0.2.1
MODBUS_HOST=192.0.2.1:502
OPCUA_ENDPOINT_URL=opc.tcp://192.0.2.1:4840
AGENT_HEALTH_PORT=9103
NODERED_UI_PORT=1880
LOG_LEVEL=info
TZ=UTC
ENV

# The config bundle (small: yaml/certs/compose) rides in the SSM document as
# base64 — it stays inside AWS SSM/CloudTrail and never lands in object storage
# (the throwaway private key never touches S3). The big IMAGES go via S3 below.
CFG_TGZ="$WORK/config-bundle.tgz"
tar czf "$CFG_TGZ" -C "$BUNDLE" .
CFG_B64="$(base64 -w0 "$CFG_TGZ")"
CFG_BYTES="$(wc -c < "$CFG_TGZ")"
echo "  config bundle: ${CFG_BYTES} bytes gz, $(printf '%s' "$CFG_B64" | wc -c) b64 chars"
[ "$(printf '%s' "$CFG_B64" | wc -c)" -lt 90000 ] || die "config bundle too big for one SSM param (>90KB b64) — split or move to S3"

# ── phase 4: acquire the REAL images (build → save → S3 → presign) ────────────
# ACQUISITION PLAN (why this shape):
#   • The Go source tree (5.9MB, 8.2MB base64) is FAR over the ~100KB SSM param
#     limit → we cannot ship source or build inline via SSM.
#   • The box is a hybrid SSM instance with NO AWS creds → it cannot pull the
#     private ECR image directly.
#   ⇒ Build the two images HERE (build host has the source + Docker), `docker save`
#     them, upload to a PRIVATE S3 bucket, and hand the box PRESIGNED URLs. The box
#     needs only curl + docker + HTTPS egress (all present); `docker load` runs on
#     the HOST, so SEVERANCE L1 (internal container network) does not block it.
AGENT_URL=""; NODERED_URL=""
if [ "$SKIP_IMAGES" = "1" ]; then
  log "phase 4 — SKIP_IMAGES=1: assuming ${AGENT_IMG} + ${NODERED_IMG} already loaded on the box"
else
  [ -n "${S3_BUCKET:-}" ] || die "set S3_BUCKET (private bucket) or SKIP_IMAGES=1"
  if [ "$SKIP_BUILD" != "1" ]; then
    log "phase 4a — build images (linux/${ARCH})"
    # Agent + all reader binaries = the FULL Dockerfile (NOT Dockerfile.agent, which
    # omits the reader binaries). One image serves sparkplug-agent + s7/modbus/opcua-reader.
    docker build --platform "linux/${ARCH}" -f "$ETSRC/Dockerfile" -t "$AGENT_IMG" "$ETSRC"
    # PLC-capable Node-RED (baked s7/modbus/opcua palettes → offline-ready, CPACK F1 fix).
    docker build --platform "linux/${ARCH}" -f "$ED/Dockerfile.nodered-reader" -t "$NODERED_IMG" "$ED"
    log "phase 4b — docker save + gzip"
    docker save "$AGENT_IMG"   | gzip > "$WORK/images/edge-transformer.tar.gz"
    docker save "$NODERED_IMG" | gzip > "$WORK/images/nodered-reader.tar.gz"
  fi
  ls -lh "$WORK/images/"
  log "phase 4c — upload to s3://${S3_BUCKET}/sbxcpack-replica/ + presign (${PRESIGN_TTL}s)"
  aws s3 cp "$WORK/images/edge-transformer.tar.gz" "s3://${S3_BUCKET}/sbxcpack-replica/edge-transformer.tar.gz" --region "$REGION"
  aws s3 cp "$WORK/images/nodered-reader.tar.gz"   "s3://${S3_BUCKET}/sbxcpack-replica/nodered-reader.tar.gz"   --region "$REGION"
  AGENT_URL="$(aws s3 presign "s3://${S3_BUCKET}/sbxcpack-replica/edge-transformer.tar.gz" --expires-in "$PRESIGN_TTL" --region "$REGION")"
  NODERED_URL="$(aws s3 presign "s3://${S3_BUCKET}/sbxcpack-replica/nodered-reader.tar.gz" --expires-in "$PRESIGN_TTL" --region "$REGION")"
fi

# ── phase 5: build the box command (loads images, drops bundle, compose up) ────
# The image-load loop is a no-op branch when SKIP_IMAGES=1 (URLs empty).
read -r -d '' BOXCMD <<BOX || true
set -e
command -v docker >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq ca-certificates curl && curl -fsSL https://get.docker.com | sh; systemctl enable --now docker; }
mkdir -p /opt/packiot/sbxcpack-replica
cd /opt/packiot/sbxcpack-replica
# stop the old public-image MOCK if present (supersede, don't stack). The mock
# lives one dir up at /opt/packiot/compose.edge.yml (provision-sandbox-edge-box.sh),
# NOT in this replica dir — check both so we never leave the mock running beside us.
[ -f /opt/packiot/compose.edge.yml ] && docker compose -f /opt/packiot/compose.edge.yml down --remove-orphans 2>/dev/null || true
[ -f compose.edge.yml ] && docker compose -f compose.edge.yml down --remove-orphans 2>/dev/null || true
# Clean-recreate the replica itself: a bare `up -d` after a compose/network change
# can leave the user-defined bridge in a stale state where Docker embedded DNS
# stops resolving service names (agent → tcp://mosquitto:1883 fails with a connect
# timeout, crash-looping). `down` first tears the network down so `up` rebuilds it
# with working DNS + aliases. Safe on a sandbox (brief recreate, no real data).
[ -f compose.replica.yml ] && docker compose -f compose.replica.yml --env-file .env down --remove-orphans 2>/dev/null || true
# 1) load the real images (host egress; runs before the internal net exists)
for url in "${AGENT_URL}" "${NODERED_URL}"; do
  [ -n "\$url" ] || continue
  echo "loading image ..."; curl -fsSL "\$url" | gunzip | docker load
done
# 2) drop the severed config bundle
echo '${CFG_B64}' | base64 -d | tar xzf - -C /opt/packiot/sbxcpack-replica
# 3) agent runs as non-root uid 65532 → make the key readable (else TLS-load crash-loop)
chown 65532:65532 certs/uplink-key.pem 2>/dev/null || chmod 0644 certs/uplink-key.pem
# 4) bring the severed replica up (COMPOSE_PROFILES is set in .env)
docker compose -f compose.replica.yml --env-file .env up -d
docker ps --format '{{.Names}} | {{.Status}}'
BOX

# ── phase 6: GUARDED deploy ───────────────────────────────────────────────────
if [ "$DEPLOY" != "1" ]; then
  log "phase 6 — DRY (guard). Nothing was sent to the box."
  cat <<EOF

Prepared locally under: $WORK
  bundle/            severed config bundle (compose + certs CN=${TENANT_SLUG} + generated yaml)
  images/*.tar.gz    real images (built linux/${ARCH})
$( [ -n "$AGENT_URL" ] && echo "  presigned image URLs valid for ${PRESIGN_TTL}s" )

To DEPLOY, re-run with DEPLOY=1 (same env), which will execute:

  aws ssm send-command --region $REGION --instance-ids $MI \\
    --document-name AWS-RunShellScript \\
    --parameters commands='[<the box script phase 5 assembled above>]'

Review docs/clients/sandbox-edge/README-severance.md and run the verification
checklist AFTER deploy to prove no data can reach real CPACK.
EOF
  exit 0
fi

log "phase 6 — DEPLOY=1: sending to $MI"
# Marshal the single-command array as JSON safely (jq if available, else python3).
if command -v jq >/dev/null 2>&1; then
  PARAMS="$(jq -nc --arg c "$BOXCMD" '{commands:[$c]}')"
else
  PARAMS="$(BOXCMD="$BOXCMD" python3 -c 'import json,os;print(json.dumps({"commands":[os.environ["BOXCMD"]]}))')"
fi
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$MI" \
  --document-name AWS-RunShellScript --parameters "$PARAMS" \
  --query 'Command.CommandId' --output text)"
echo ">> SendCommand $CID"
echo ">> poll: aws ssm get-command-invocation --command-id $CID --instance-id $MI --region $REGION --query 'StandardOutputContent' --output text"
