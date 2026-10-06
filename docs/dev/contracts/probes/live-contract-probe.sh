#!/usr/bin/env bash
# live-contract-probe.sh — READ-ONLY runtime evidence for docs/dev/contracts.md (P0, ADR-0060).
#
# Runs ON the staging app host as root (ssm-user is not in the docker group). It changes nothing:
# docker ps/inspect, nsenter+ss (socket listing), rabbitmqctl list_*, and one SELECT inside
# BEGIN READ ONLY. It never pulls an image (the 2026-10-06 first run pulled postgres:15 — fixed).
# Secrets: env VALUES are never printed (keys only); the DB URL stays in a shell variable.
#
# How it was run (SSM RunShellCommand is policy-blocked; StartNonInteractiveCommand works, argv
# is split on spaces and NOT run through a shell, hence `bash -c` + a space-free ${IFS} payload):
#   B64=$(base64 -w0 live-contract-probe.sh)
#   jq -n --arg c "bash -c echo\${IFS}$B64|base64\${IFS}-d|sudo\${IFS}bash" '{command:[$c]}' > params.json
#   script -qec "aws ssm start-session --target i-06c9547a2c7091ab7 \
#     --document-name AWS-StartNonInteractiveCommand --parameters file://params.json" /dev/null > out.txt
set -uo pipefail

echo "### 1. containers: name | image | created | status"
docker ps --format '{{.Names}}|{{.Image}}|{{.CreatedAt}}|{{.Status}}' | sort

echo "### 2. per container: IPs + env KEYS (no values)"
for c in $(docker ps --format '{{.Names}}' | sort); do
  echo "== $c $(docker inspect "$c" --format '{{range $n,$v := .NetworkSettings.Networks}}{{$n}}={{$v.IPAddress}} {{end}}')"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1 | sort | tr '\n' ' '; echo
done

echo "### 3. rabbitmq topology + clients"
RMQ=$(docker ps --format '{{.Names}}' | grep -m1 rabbitmq)
docker exec "$RMQ" rabbitmqctl -q list_exchanges name type durable
docker exec "$RMQ" rabbitmqctl -q list_queues name durable consumers messages
docker exec "$RMQ" rabbitmqctl -q list_bindings source_name destination_name routing_key
docker exec "$RMQ" rabbitmqctl -q list_connections peer_host
docker exec "$RMQ" rabbitmqctl -q list_consumers queue_name ack_required

echo "### 4. established TCP connections per container (inside each netns)"
# Logs only show NEW connections; long-lived clients (MQTT, AMQP, pools) are only visible here.
for c in $(docker ps --format '{{.Names}}' | sort); do
  pid=$(docker inspect -f '{{.State.Pid}}' "$c")
  echo "== $c"
  nsenter -t "$pid" -n ss -Htn state established 2>/dev/null | awk '{print $3, "->", $4}' | sort | uniq -c
done

echo "### 5. IP -> container"
docker ps -q | xargs docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}} {{.Name}}' | sort

echo "### 6. postgres sessions grouped (read-only)"
IMG=postgres:15-alpine
docker image inspect "$IMG" >/dev/null 2>&1 || { echo "SKIP: $IMG not present, refusing to pull"; exit 0; }
URL=$(docker inspect stack-edge-api-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_ANALYTICS_URL=' | cut -d= -f2-)
URL=${URL/@pgbouncer:5432/@10.10.10.89:5432}
[ -n "$URL" ] || { echo "SKIP: no POSTGRES_ANALYTICS_URL"; exit 0; }
docker run --rm --network host "$IMG" psql "$URL" -qAtF '|' -c "BEGIN READ ONLY;
  SELECT coalesce(host(client_addr),'local'), application_name, usename, datname, state, count(*)
  FROM pg_stat_activity WHERE backend_type='client backend'
  GROUP BY 1,2,3,4,5 ORDER BY 1,2,3; COMMIT;"

echo "### 7. role/database settings, role attributes, versions (read-only)"
docker run --rm --network host "$IMG" psql "$URL" -qAtF '|' -c "BEGIN READ ONLY;
  SELECT coalesce(r.rolname,'*'), coalesce(d.datname,'*'), s.setconfig FROM pg_db_role_setting s
    LEFT JOIN pg_roles r ON r.oid=s.setrole LEFT JOIN pg_database d ON d.oid=s.setdatabase ORDER BY 1,2;
  SELECT rolname, rolsuper, rolbypassrls, rolcanlogin FROM pg_roles
    WHERE rolname IN ('postgres','readapi_ro','superset_ro','superset','histgw_ro') ORDER BY 1;
  SELECT current_setting('server_version'), (SELECT extversion FROM pg_extension WHERE extname='timescaledb');
  COMMIT;"
