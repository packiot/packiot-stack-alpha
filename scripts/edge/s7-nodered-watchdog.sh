#!/bin/bash
# s7-nodered-watchdog — self-heal wedged S7 endpoint connections on the CPACK edge.
# 2026-08-13 incident: a node-red "s7 endpoint" sticks on "Timeout connecting to
# the transport" and never self-recovers, silently dropping whole lines
# (L8/L10/CELULA) for days. A full Node-RED flows RELOAD re-establishes the S7
# sessions (proven fix, 2026-08-21). Reacts to that exact persistent error,
# rate-limited, logs to syslog (tag s7-watchdog). Runs as user 'packiot'
# (docker group), no root needed.
set -uo pipefail
NR="http://localhost:1880"
CT="edge-cpack-nodered"
STATE="$HOME/.s7-watchdog/last_reload"
WINDOW="6m"          # error must be present within this recent window
COOLDOWN=720         # min seconds between reloads (12 min) — avoids reload loops
mkdir -p "$(dirname "$STATE")" 2>/dev/null
if docker logs --since "$WINDOW" "$CT" 2>&1 \
   | grep -qiE '\[s7 endpoint:[^]]*\].*(Timeout connecting to the transport|Request timeout)'; then
  now=$(date +%s); last=$(cat "$STATE" 2>/dev/null || echo 0)
  if [ $(( now - last )) -ge "$COOLDOWN" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$NR/flows" \
      -H 'Node-RED-Deployment-Type: reload' -H 'Content-Type: application/json' --data '{}' 2>/dev/null || echo 000)
    logger -t s7-watchdog "persistent S7 transport-timeout on $CT -> node-red flows reload (HTTP $code)"
    echo "$now" > "$STATE"
  else
    logger -t s7-watchdog "S7 timeout present but within cooldown ($((now-last))s<${COOLDOWN}s) - skip"
  fi
fi
