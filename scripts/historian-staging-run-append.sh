#!/usr/bin/env bash
# Staging historian daily append wrapper — F3 staging analytics -> S3 cold store.
# Deployed to /opt/packiot/historian/ ; invoked by historian-staging-append.timer.
set -euo pipefail; export HOME="${HOME:-/root}"
PGPW="$(docker inspect stream-engine --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | head -1 | cut -d= -f2-)"
HISTORIAN_APPEND_ENABLED=true \
HISTORIAN_BUCKET="${HISTORIAN_BUCKET:-packiot-staging-historian-639178078294}" \
HISTORIAN_APPEND_ENTERPRISES="${HIST_ENTS:-3 5}" \
HISTORIAN_OVERLAP_DAYS="${HIST_OVERLAP:-2}" \
SRC_PGHOST=10.10.10.89 SRC_PGPORT=5432 SRC_PGUSER=postgres SRC_PGPASSWORD="$PGPW" SRC_PGDATABASE=packiot_analytics \
/opt/packiot/historian/historian-append.sh
