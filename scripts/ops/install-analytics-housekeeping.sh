#!/usr/bin/env bash
# install-analytics-housekeeping.sh — install + enable the analytics housekeeping timers on a DB host without pg_cron
# (production, go-live-bispharma.md §6 step 8b). Idempotent. Run as root from a checkout:
#   sudo bash scripts/ops/install-analytics-housekeeping.sh            # enable
#   sudo bash scripts/ops/install-analytics-housekeeping.sh --disable  # stop + disable (keeps the files)
set -euo pipefail
cd "$(dirname "$0")/../.."
JOBS="partition-maintain downtime-resolved data-invariants"
if [ "${1:-}" = --disable ]; then
  for j in $JOBS; do systemctl disable --now "analytics-housekeeping@$j.timer" || true; done; exit 0
fi
install -d -m 0755 /opt/packiot/ops
install -m 0755 scripts/ops/analytics-housekeeping.sh /opt/packiot/ops/analytics-housekeeping.sh
install -m 0644 systemd/analytics-housekeeping@.service /etc/systemd/system/
for j in $JOBS; do install -m 0644 "systemd/analytics-housekeeping@$j.timer" /etc/systemd/system/; done
systemctl daemon-reload
for j in $JOBS; do systemctl enable --now "analytics-housekeeping@$j.timer"; done
systemctl list-timers 'analytics-housekeeping@*' --no-pager
