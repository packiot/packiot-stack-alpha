#!/usr/bin/env bash
# install-data-invariants.sh — install the out-of-DB data invariants on the app box:
#   /opt/packiot/ops/{invariant-record.sh,data-oracle-check.sh} + data-oracle-check.{service,timer}
# The in-DB invariants run as a Timescale job (migration t-data-invariants); both write
# ops.data_invariant_result → postgres-exporter → Prometheus DataInvariant* alerts → Slack.
# Also re-installs the historian monitor scripts so its result is recorded (H1).
# Idempotent. Run as root from a checkout of the repo.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST=/opt/packiot/ops
UNIT_DIR=/etc/systemd/system
install -d -m 0755 "$DEST"
install -m 0755 "$REPO_ROOT/scripts/ops/invariant-record.sh"  "$DEST/invariant-record.sh"
install -m 0755 "$REPO_ROOT/scripts/ops/data-oracle-check.sh" "$DEST/data-oracle-check.sh"
install -m 0644 "$REPO_ROOT/systemd/data-oracle-check.service" "$UNIT_DIR/data-oracle-check.service"
install -m 0644 "$REPO_ROOT/systemd/data-oracle-check.timer"   "$UNIT_DIR/data-oracle-check.timer"
if [ -d /opt/packiot/historian ]; then
  install -m 0755 "$REPO_ROOT/scripts/historian-integrity-monitor.sh" /opt/packiot/historian/historian-integrity-monitor.sh
fi
systemctl daemon-reload
systemctl enable --now data-oracle-check.timer
echo "[install-data-invariants] installed; next run: $(systemctl show -p NextElapseUSecRealtime --value data-oracle-check.timer)"
