#!/usr/bin/env bash
# Staging historian daily job — copies LEGACY packiot40 -> S3 COLD store, then stamps the
# watermark + refreshes the union boundaries. Deployed to /opt/packiot/historian/ ; invoked
# by historian-staging-append.timer.
set -euo pipefail; export HOME="${HOME:-/root}"
# COLD = a TEMPORARY scheduled COPY of legacy packiot40, remapped legacy->F3 (validated == the
# #167 packml-topic map) + translated to the 56-col hist schema, so COLD holds the COMPLETE
# (all-machine) history/recent. LIVE data is served from analytics (hot FDW) — NOT copied here.
# Retired at the #225 legacy cutover. (Was: F3-analytics -> cold append, which wrote files the
# cold view's *-legacy.parquet glob never read; superseded by this legacy copy.)
/opt/packiot/historian/historian-legacy-copy.sh

# production_orders cold archive — incremental (current + previous month), same legacy->F3 remap.
# The one-time deep backfill to 2021 is a manual run with PO_COPY_MONTHS_BACK=60; the daily job
# keeps the recent tail archived so silver.production_orders stays continuous across the cutover.
PO_COPY_MONTHS_BACK="${PO_COPY_MONTHS_BACK:-1}" /opt/packiot/historian/historian-po-backfill.sh

# ── POST-RUN HOOK (R3 refresh + R5 stamp) — the pipeline that EXTENDS the cold store
# OWNS the boundary refresh. `set -e` fails the whole job if any step errors, so a
# broken refresh can never silently leave equipment_values_all double-counting. Order matters:
# stamp cold_append_watermark FIRST (so a present refresh leaves refreshed_at >= last_append_at),
# then refresh the EV boundary (a TOP-LEVEL parquet scan — never a function), then EE.
GW="${GATEWAY_CONTAINER:-hist-gateway}"
echo "[historian-append] post-run: stamp cold_append_watermark (R5) + refresh cutover boundaries (R3)"
docker exec -i "$GW" psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < /opt/packiot/historian/stamp-equipment_values-meta.sql
docker exec -i "$GW" psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < /opt/packiot/historian/refresh-equipment_values-cutover.sql
docker exec -i "$GW" psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < /opt/packiot/historian/refresh-ee-cutover.sql
docker exec -i "$GW" psql -U postgres -d packiot_historian -v ON_ERROR_STOP=1 -f - < /opt/packiot/historian/refresh-po-cutover.sql
echo "[historian-append] post-run hook complete (cold_append_watermark stamped, cutover boundaries refreshed: EV+EE+PO)"
