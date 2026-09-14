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

# ── POST-RUN HOOK (R3 refresh + R5 stamp) — the pipeline that EXTENDS the cold store
# OWNS the boundary refresh. `set -e` fails the whole job if any step errors, so a
# broken refresh can never silently leave ev_all double-counting. Order matters:
# stamp hist_meta FIRST (so a present refresh leaves refreshed_at >= last_append_at),
# then refresh the EV boundary (a TOP-LEVEL parquet scan — never a function), then EE.
GW="${GATEWAY_CONTAINER:-hist-gateway}"
echo "[historian-append] post-run: stamp hist_meta (R5) + refresh cutover boundaries (R3)"
docker exec -i "$GW" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < /opt/packiot/historian/stamp-hist-meta.sql
docker exec -i "$GW" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < /opt/packiot/historian/refresh-hist-cutover.sql
docker exec -i "$GW" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < /opt/packiot/historian/refresh-ee-cutover.sql
echo "[historian-append] post-run hook complete (hist_meta stamped, cutover boundaries refreshed)"
