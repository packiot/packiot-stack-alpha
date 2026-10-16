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
INGEST_PORT=$(envdef DEV_INGEST_SHIM_PORT 8444)
OPGW_PORT=$(envdef DEV_OPERATOR_GATEWAY_PORT 8445)
RMQ_MGMT="http://127.0.0.1:$(envdef DEV_RABBITMQ_MGMT_PORT 15672)/api"
RMQ_AUTH="$(envdef RABBITMQ_USER packiot-dev):$(envdef RABBITMQ_PASSWORD packiot-dev)"
SEED_GROUP=$(envdef DEV_SEED_GROUP '')
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
# RabbitMQ management API (admin user from .env.dev). A smoke that must SEE a routed message binds its own
# short-lived queue (x-expires) to `oee` and reads it back, so it never consumes a service's queue.
rmq() { curl -sS -m 20 -u "$RMQ_AUTH" -H 'Content-Type: application/json' "$@"; }
tapq() { # tapq <name> <routing-key>: a temporary queue bound to oee
  rmq -X PUT -d '{"durable":false,"auto_delete":false,"arguments":{"x-expires":300000}}' "$RMQ_MGMT/queues/%2F/$1" >/dev/null
  rmq -X POST -d "{\"routing_key\":\"$2\"}" "$RMQ_MGMT/bindings/%2F/e/oee/q/$1" >/dev/null
}
tapget() { # tapget <name> <marker>: poll the tap queue until a message containing <marker> shows up; prints it
  local t0=$SECONDS out
  while [ $((SECONDS - t0)) -lt 30 ]; do
    out=$(rmq -X POST -d '{"count":500,"ackmode":"ack_requeue_false","encoding":"auto"}' "$RMQ_MGMT/queues/%2F/$1/get" \
          | python3 -c 'import json,sys; m=sys.argv[1]; [print(x["payload"]) for x in json.load(sys.stdin) if m in x["payload"]]' "$2" 2>/dev/null)
    [ -n "$out" ] && { printf '%s' "$out" | head -1; return 0; }
    sleep 1
  done
  return 1
}
taprm() { rmq -X DELETE "$RMQ_MGMT/queues/%2F/$1" >/dev/null; }
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
  analytics-sync)
    # staging runs it idle (SHADOW_MIRROR_ENABLED=false: its F1 source DB is retired), and so does dev: the only thing
    # to prove is that the binary boots, answers health and exposes its replay metrics
    expect "analytics-sync: /healthz (in-network)" 200 "$(inside http://analytics-sync:9103/healthz)"
    expect "analytics-sync: /metrics exposes the replay cursor" 200 "$(inside http://analytics-sync:9103/metrics)" "grep -q '^shadow_mirror_cursor '"
    r=$("${DC[@]}" logs --no-log-prefix analytics-sync 2>&1 | grep -c 'service idle')
    [ "$r" -gt 0 ] && ok "analytics-sync: idle like staging (SHADOW_MIRROR_ENABLED=false)" || bad "analytics-sync: no idle-mode log line" ;;
  ingest-shim)
    expect "ingest-shim: TLS /healthz (AMQP publisher up)" 200 "$(http -k "https://127.0.0.1:$INGEST_PORT/healthz")" "grep -q '\"ok\"'"
    expect "ingest-shim: no X-Ingest-Key → 401" 401 "$(http -k -d '{}' "https://127.0.0.1:$INGEST_PORT/ingest/sparkplug")"
    expect "ingest-shim: out-of-scope group → 403" 403 \
      "$(http -k -H "X-Ingest-Key: $(envdef DEV_INGEST_API_KEY '')" -d '{"metrics":[{"name":"OTHER/x","value":1}]}' "https://127.0.0.1:$INGEST_PORT/ingest/sparkplug")"
    # the real path: POST → publisher confirm → `oee` with the staging routing key, source_type stamped (fan-out)
    local q="smoke-ingest-shim-$$" mk="smoke-$$-$RANDOM" msg
    tapq "$q" sparkplug.data.incoplast
    expect "ingest-shim: POST /ingest/sparkplug → 202" 202 \
      "$(http -k -H "X-Ingest-Key: $(envdef DEV_INGEST_API_KEY '')" -d "{\"metrics\":[{\"name\":\"INCOPLAST/SMOKE/$mk\",\"value\":1,\"timestamp\":$(date +%s000)}]}" "https://127.0.0.1:$INGEST_PORT/ingest/sparkplug")"
    if msg=$(tapget "$q" "$mk") && [[ "$msg" == *'"source_type":"refactored"'* ]]; then
      ok "ingest-shim: envelope routed on oee/sparkplug.data.incoplast with source_type=refactored"
    else bad "ingest-shim: published envelope not seen on oee/sparkplug.data.incoplast: ${msg:0:200}"; fi
    taprm "$q" ;;
  oeecloud-fanout)
    expect "oeecloud-fanout: /health (in-network)" 200 "$(inside http://oeecloud-fanout:9102/health)" "grep -q '\"healthy\":true'"
    # publish one envelope of the seed group on a source key; the fanout must re-tenant it onto sparkplug.data.sbxcpack.
    # sparkplug.data.cpack, not the firehose: in dev only the (unconsumed) stream-engine-q-cpack also binds it, so the
    # synthetic envelope never reaches a running stream-engine.
    local q="smoke-fanout-$$" mk="smoke-$$-$RANDOM" msg pub
    tapq "$q" sparkplug.data.sbxcpack
    pub=$(python3 -c 'import json,sys,time; print(json.dumps({"routing_key":"sparkplug.data.cpack","properties":{"content_type":"application/json"},"payload_encoding":"string","payload":json.dumps({"metrics":[{"name":sys.argv[1]+"/SMOKE/"+sys.argv[2],"value":1,"timestamp":int(time.time()*1000)}],"id_enterprise":3})}))' "$SEED_GROUP" "$mk")
    r=$(rmq -X POST -d "$pub" "$RMQ_MGMT/exchanges/%2F/oee/publish")
    [[ "$r" == *'"routed":true'* ]] && ok "oeecloud-fanout: test envelope published on oee/sparkplug.data.cpack" || bad "oeecloud-fanout: publish: $r"
    if msg=$(tapget "$q" "$mk") && [[ "$msg" == *"\"SBXCPACK/SMOKE/$mk\""* && "$msg" != *id_enterprise* ]]; then
      ok "oeecloud-fanout: clone on sparkplug.data.sbxcpack, group rewritten to SBXCPACK, source tenant id cleared"
    else bad "oeecloud-fanout: no re-tenanted clone seen: ${msg:0:200}"; fi
    taprm "$q" ;;
  operator-gateway)
    local key; key=$(envdef DEV_OPERATOR_GATEWAY_KEY '')
    expect "operator-gateway: TLS /healthz (resolver DB pool)" 200 "$(http -k "https://127.0.0.1:$OPGW_PORT/healthz")" "grep -q '\"db\":true'"
    expect "operator-gateway: no X-Ingest-Key → 401" 401 "$(http -k -d '{}' "https://127.0.0.1:$OPGW_PORT/operator/downtime")"
    expect "operator-gateway: unknown topic → 422 (resolver fails closed)" 422 \
      "$(http -k -H "X-Ingest-Key: $key" -d "{\"enterprise\":3,\"packml_topic\":\"$SEED_GROUP/NOPE/$$\",\"id_param\":30811,\"ts_event\":\"2026-01-01T00:00:00Z\",\"ts_end\":\"2026-01-01T00:01:00Z\",\"category\":\"x\",\"category_desc\":\"x\"}" "https://127.0.0.1:$OPGW_PORT/operator/downtime")"
    # the real path: topic → seed equipment (packml_register) → edge-api create-manual-event (x-api-key injected) → row
    local topic eq ts te before after
    IFS='|' read -r topic eq <<<"$(psqlq "SELECT p.packml_topic, p.id_equipment FROM packml_register p JOIN equipments e USING (id_equipment) WHERE p.active AND e.id_enterprise = 3 AND e.tp_equipment = 3 ORDER BY p.id_equipment LIMIT 1")"
    ts=$(date -u -d "-$((60 + RANDOM % 600)) minutes" +%Y-%m-%dT%H:%M:00Z); te=$(date -u -d "$ts + 2 minutes" +%Y-%m-%dT%H:%M:%SZ)
    before=$(psqlq "SELECT count(*) FROM silver.equipment_events_man WHERE id_equipment = $eq")
    expect "operator-gateway: POST /operator/downtime (seed line $eq) → edge-api" 202 \
      "$(http -k -H "X-Ingest-Key: $key" -d "{\"enterprise\":3,\"packml_topic\":\"$topic\",\"id_param\":30811,\"ts_event\":\"$ts\",\"ts_end\":\"$te\",\"category\":\"SMOKE\",\"category_desc\":\"dev smoke\",\"txt_downtime\":\"dev smoke $$\"}" "https://127.0.0.1:$OPGW_PORT/operator/downtime")"
    after=$(psqlq "SELECT count(*) FROM silver.equipment_events_man WHERE id_equipment = $eq")
    [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ && "$after" -gt "$before" ]] && ok "operator-gateway: manual event written for equipment $eq ($before → $after)" \
      || bad "operator-gateway: no new manual event row for equipment $eq ($before → $after)" ;;
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
