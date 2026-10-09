#!/usr/bin/env bash
# dev/e2e/smoke.sh — per-service smoke check for the dev slices (ADR-0060 D8).
#
#   make dev SVC="edge-api" && make dev-smoke SVC="edge-api"
#   bash dev/e2e/smoke.sh postgres read-api edge-api      # several at once
#
# Each check = health + ONE real request that goes through the service to its data (a DB row, a proxied API
# call), so "the container is up" is never mistaken for "the service works". No Cognito login is needed:
# reads/writes use the seed's fake keys (enterprises.api_key = dev-api-key-3, read-api QUERY_API_KEYS
# dev-read-key-3). Bearer-only paths (barcode-service) are checked fail-closed (401 without a token).
# Talks only to 127.0.0.1 host ports and, for services without a host port, to the compose network.
# Exit code = number of failed services (0 = all green).
set -uo pipefail
cd "$(dirname "$0")/../.."

DC=(docker compose -f dev/compose.yml --env-file dev/.env.dev)
NET=${DEV_NETWORK:-packiot-dev_default}
envdef() { local v; v=$(grep -E "^$1=" dev/.env.dev | tail -1 | cut -d= -f2-); printf '%s' "${!1:-${v:-$2}}"; }
PG_PORT=$(envdef DEV_PG_PORT 5432)
GRAFANA_PORT=$(envdef DEV_GRAFANA_PORT 3000)
READAPI_PORT=$(envdef DEV_READAPI_PORT 9104)
EDGE_PORT=$(envdef DEV_EDGE_API_PORT 8080)
BARCODE_PORT=$(envdef DEV_BARCODE_PORT 8446)
OPERATOR_PORT=$(envdef DEV_OPERATOR_PORT 8083)
CSADMIN_PORT=$(envdef DEV_CSADMIN_PORT 8084)
CUSTOMIZE_PORT=$(envdef DEV_CUSTOMIZE_PORT 8086)
POOL_ID=$(envdef DEV_COGNITO_USER_POOL_ID '')
EDGE_KEY=${DEV_SMOKE_EDGE_API_KEY:-dev-api-key-3}
READ_KEY=${DEV_SMOKE_READ_KEY:-dev-read-key-3}
TIMEOUT=${SMOKE_TIMEOUT:-180}   # seconds to wait for eventually-consistent checks (pipeline)

ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILED=1; }
psqlq() { "${DC[@]}" exec -T postgres psql -X -U "$(envdef POSTGRES_USER postgres)" -d packiot_analytics -tAc "$1" 2>&1; }
# GET/POST returning "<status> <body>"; curl never fails the script by itself
http() { local out code; out=$(curl -sS -m 20 -o /dev/stdout -w '\n%{http_code}' "$@" 2>&1); code=${out##*$'\n'}; printf '%s %s' "$code" "${out%$'\n'*}"; }
# the same, from inside the compose network (services with no host port)
inside() { local out code; out=$(docker run --rm --network "$NET" curlimages/curl:8.10.1 -sS -m 20 -o /dev/stdout -w '\n%{http_code}' "$@" 2>&1); code=${out##*$'\n'}; printf '%s %s' "$code" "${out%$'\n'*}"; }
# JSON array with ≥1 element
nonempty_array() { python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) and len(d)>0 else 1)'; }
expect() { # expect <label> <want-status> <response> [check-cmd]
  local label=$1 want=$2 resp=$3 code body; code=${resp%% *}; body=${resp#* }
  if [ "$code" != "$want" ]; then bad "$label: HTTP $code (want $want): ${body:0:200}"; return; fi
  if [ $# -ge 4 ] && ! printf '%s' "$body" | eval "$4" >/dev/null 2>&1; then bad "$label: unexpected body: ${body:0:200}"; return; fi
  ok "$label"
}
spa() { # spa <name> <port>: index served + the dev pool id is baked into the bundle (not staging's)
  local name=$1 port=$2 html js
  html=$(http "http://127.0.0.1:$port/")
  expect "$name: GET / serves the SPA" 200 "$html" "grep -q '<div id=\"root\"'"
  js=$(printf '%s' "${html#* }" | grep -oE '/assets/[^"]+\.js' | head -1)
  # whole bundle into a variable first: `curl | grep -q` dies of SIGPIPE under pipefail
  if [ -n "$js" ] && [ -n "$POOL_ID" ] && [[ "$(curl -fsS -m 20 "http://127.0.0.1:$port$js")" == *"$POOL_ID"* ]]; then
    ok "$name: bundle carries the dev Cognito pool ($POOL_ID)"
  else bad "$name: dev Cognito pool id not found in the bundle ($js)"; fi
}

smoke() {
  case "$1" in
  postgres)
    r=$(psqlq "SELECT count(*) FROM silver.equipment_values")
    [[ "$r" =~ ^[0-9]+$ && "$r" -gt 0 ]] && ok "postgres: seed loaded ($r silver rows)" || bad "postgres: no seed rows: $r"
    r=$(psqlq "SELECT count(*) FROM pg_sequences s WHERE s.last_value IS NOT NULL AND s.schemaname='public' AND s.sequencename='knex_migrations_id_seq' AND s.last_value >= (SELECT max(id) FROM public.knex_migrations)")
    [ "$r" = 1 ] && ok "postgres: id sequences synced past the seed (F11)" || bad "postgres: knex_migrations_id_seq behind the seed's ids: $r" ;;
  rabbitmq)
    r=$("${DC[@]}" exec -T rabbitmq rabbitmqctl -q list_exchanges name 2>&1 | grep -cxE 'oee|oee-retry|oee-failed')
    [ "$r" = 3 ] && ok "rabbitmq: oee topology loaded" || bad "rabbitmq: oee exchanges missing ($r/3)" ;;
  mosquitto)
    "${DC[@]}" exec -T mosquitto timeout 5 mosquitto_pub -h 127.0.0.1 -t smoke/ping -m ok -q 1 >/dev/null 2>&1 \
      && ok "mosquitto: publish QoS 1" || bad "mosquitto: publish failed" ;;
  redis)
    r=$("${DC[@]}" exec -T redis redis-cli ping 2>&1); [ "$r" = PONG ] && ok "redis: PONG" || bad "redis: $r" ;;
  minio)
    expect "minio: live" 200 "$(http "http://127.0.0.1:$(envdef DEV_MINIO_PORT 9000)/minio/health/live")" ;;
  grafana)
    expect "grafana: /api/health" 200 "$(http "http://127.0.0.1:$GRAFANA_PORT/api/health")"
    q='{"queries":[{"refId":"A","datasource":{"uid":"packiot-postgres-shadow"},"rawSql":"SELECT count(*) AS n FROM silver.equipment_values","format":"table"}],"from":"now-1h","to":"now"}'
    expect "grafana: datasource packiot-postgres-shadow answers a SQL query" 200 \
      "$(http -u "admin:$(envdef GRAFANA_ADMIN_PASSWORD admin)" -H 'Content-Type: application/json' -d "$q" "http://127.0.0.1:$GRAFANA_PORT/api/ds/query")" \
      "python3 -c 'import json,sys; d=json.load(sys.stdin); v=d[\"results\"][\"A\"][\"frames\"][0][\"data\"][\"values\"][0][0]; sys.exit(0 if v>0 else 1)'" ;;
  read-api)
    expect "read-api: /healthz" 200 "$(inside http://read-api:9104/healthz)"
    expect "read-api: GET /v1/operator-entities (tenant 3 by read key)" 200 \
      "$(inside -H "X-Api-Key: $READ_KEY" http://read-api:9104/v1/operator-entities)" nonempty_array
    expect "read-api: no key → 401 (fail closed)" 401 "$(inside http://read-api:9104/v1/operator-entities)" ;;
  read-api-cors)
    expect "read-api-cors: preflight answered with the dev origin" 204 \
      "$(http -X OPTIONS -H "Origin: $(envdef DEV_CORS_ORIGIN http://localhost:5173)" -H 'Access-Control-Request-Method: POST' "http://127.0.0.1:$READAPI_PORT/v1/query")"
    expect "read-api-cors: proxied query carries Access-Control-Allow-Origin" 200 \
      "$(http -D - -H "X-Api-Key: $READ_KEY" "http://127.0.0.1:$READAPI_PORT/v1/operator-entities")" "grep -qi '^access-control-allow-origin:'" ;;
  front4)
    expect "front4: Vite dev server" 200 "$(http "http://127.0.0.1:5173/")" "grep -q '<div id=\"root\"'" ;;
  sparkplug-decoder)
    expect "sparkplug-decoder: /healthz (in-network)" 200 "$(inside http://sparkplug-decoder:9102/healthz)" ;;
  stream-engine)
    expect "stream-engine: /health (in-network)" 200 "$(inside http://stream-engine:9101/health)" ;;
  seed-replay)
    # the whole live pipeline: replay → MQTT → decoder → RabbitMQ → stream-engine → silver at "now"
    local t0=$SECONDS r=0
    while [ $((SECONDS - t0)) -lt "$TIMEOUT" ]; do
      r=$(psqlq "SELECT count(*) FROM silver.equipment_values WHERE ts_value > now() - interval '3 minutes'")
      [[ "$r" =~ ^[0-9]+$ && "$r" -gt 0 ]] && break; sleep 10
    done
    [[ "$r" =~ ^[0-9]+$ && "$r" -gt 0 ]] && ok "seed-replay: live silver rows at now ($r in the last 3 min, after $((SECONDS - t0)) s)" \
      || bad "seed-replay: no silver rows newer than 3 min after ${TIMEOUT}s: $r" ;;
  edge-api|edge-api-migrate)
    expect "edge-api: /health" 200 "$(http "http://127.0.0.1:$EDGE_PORT/health")"
    r=$(psqlq "SELECT (SELECT count(*) FROM public.knex_migrations) || '/' || $(find edge-api/migrations -maxdepth 1 -name '*.ts' 2>/dev/null | wc -l)")
    [ "${r%/*}" = "${r#*/}" ] && ok "edge-api: knex ledger complete ($r migrations)" || bad "edge-api: knex ledger vs files: $r"
    expect "edge-api: GET /api/lines (x-api-key, tenant 3)" 200 \
      "$(http -H "x-api-key: $EDGE_KEY" "http://127.0.0.1:$EDGE_PORT/api/lines")" nonempty_array
    expect "edge-api: no credential → 401" 401 "$(http "http://127.0.0.1:$EDGE_PORT/api/lines")" ;;
  barcode-service)
    expect "barcode-service: /healthz (DB ping)" 200 "$(http "http://127.0.0.1:$BARCODE_PORT/healthz")" "grep -q '\"healthy\":true'"
    expect "barcode-service: POST /v1/scans without a token → 401 (fail closed)" 401 \
      "$(http -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$BARCODE_PORT/v1/scans")"
    # the write path's tables and columns, as the service resolves them (search_path): a schema drift fails here
    r=$(psqlq "SELECT count(*) FROM (SELECT box_scan_id, label_seq FROM box_scans LIMIT 0) a, (SELECT id_production_order, id_enterprise, last_label_seq, total_qty, updated_at FROM po_box_counter LIMIT 0) b; SELECT count(*) FROM production_orders WHERE id_enterprise = 3")
    [[ "$(printf '%s' "$r" | tail -1)" =~ ^[1-9][0-9]*$ ]] && ok "barcode-service: write-path tables resolve; tenant 3 has POs" || bad "barcode-service: schema/data: $r" ;;
  csadmin)
    spa csadmin "$CSADMIN_PORT"
    expect "csadmin: nginx /api → edge-api" 200 "$(http -H "x-api-key: $EDGE_KEY" "http://127.0.0.1:$CSADMIN_PORT/api/lines")" nonempty_array
    expect "csadmin: nginx /v1 → read-api (refdata-api alias)" 200 \
      "$(http -H "X-Api-Key: $READ_KEY" "http://127.0.0.1:$CSADMIN_PORT/v1/operator-entities")" nonempty_array ;;
  customize)
    spa customize "$CUSTOMIZE_PORT"
    expect "customize: nginx /api → edge-api" 200 "$(http -H "x-api-key: $EDGE_KEY" "http://127.0.0.1:$CUSTOMIZE_PORT/api/lines")" nonempty_array ;;
  operator)
    spa operator "$OPERATOR_PORT"
    # no credential from the client: the image's nginx injects both keys (the operator browser holds none)
    expect "operator: /api → edge-api with the injected x-api-key" 200 "$(http "http://127.0.0.1:$OPERATOR_PORT/api/lines")" nonempty_array
    expect "operator: /v1 → read-api with the injected read key" 200 "$(http "http://127.0.0.1:$OPERATOR_PORT/v1/operator-entities")" nonempty_array ;;
  *) bad "$1: no smoke defined (add one to dev/e2e/smoke.sh)" ;;
  esac
}

[ $# -gt 0 ] || set -- postgres rabbitmq mosquitto redis minio
FAILS=0
for svc in "$@"; do
  echo "── $svc"
  FAILED=0; smoke "$svc"; FAILS=$((FAILS + FAILED))
done
[ "$FAILS" = 0 ] && echo "smoke: all ${#@} service(s) green" || echo "smoke: $FAILS service(s) FAILED"
exit "$FAILS"
