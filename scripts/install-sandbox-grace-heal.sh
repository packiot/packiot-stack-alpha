#!/usr/bin/env bash
# install-sandbox-grace-heal.sh — install the sandbox twin grace-period self-heal on the
# staging app box: the session CLI + the provisioner it calls into /opt/packiot/sandbox,
# and the 5-min systemd timer (sandbox-grace-heal.timer → sandbox-session.sh tick).
# Idempotent. The Sandbox Self-Heal workflow re-runs it on every run (nightly + manual),
# so the installed copy tracks the repo instead of drifting.
#
# Run as root:  sudo scripts/install-sandbox-grace-heal.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST=/opt/packiot/sandbox
UNIT_DIR=/etc/systemd/system

echo "[install-sandbox] repo=$REPO_ROOT dest=$DEST"
install -d -m 0755 "$DEST"
for s in sandbox-session.sh provision-sandbox-tenant.sh; do
  install -m 0755 "$REPO_ROOT/scripts/$s" "$DEST/$s"
done
for u in sandbox-grace-heal.service sandbox-grace-heal.timer; do
  install -m 0644 "$REPO_ROOT/systemd/$u" "$UNIT_DIR/$u"
done
systemctl daemon-reload
systemctl enable --now sandbox-grace-heal.timer
systemctl list-timers sandbox-grace-heal.timer --no-pager 2>/dev/null | head -3 || true
echo "[install-sandbox] done."
