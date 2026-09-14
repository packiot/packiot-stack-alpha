#!/usr/bin/env bash
# install-historian-pipeline.sh — CODIFIED install of the staging historian
# cold-archive pipeline. Idempotent; re-run on every deploy so /opt/packiot/historian
# can never drift from the repo again (that drift is what silently left the union
# boundary un-refreshed and #281's file-rename half-applied — see task #282).
#
# What it installs:
#   • the appender + FULL wrapper (append → stamp watermark → refresh EV+EE boundary)
#   • the 4 integrity/coverage monitor scripts + their SQL
#   • the systemd .service/.timer units, then enables the timers
# The timer ExecStart is the FULL wrapper (historian-staging-run-append.sh), NOT the
# append-only run-staging-append.sh — so the DB cutover boundary auto-refreshes every
# run (set -e in the wrapper fails the job loudly if a refresh errors, so the union
# can never silently double-count).
#
# Run as root (the deploy step calls it via sudo):  sudo scripts/install-historian-pipeline.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST=/opt/packiot/historian
UNIT_DIR=/etc/systemd/system

echo "[install-historian] repo=$REPO_ROOT dest=$DEST"
install -d -m 0755 "$DEST"

# ── 1. scripts (executable) — appender + full wrapper + monitors ──────────────
SCRIPTS=(
  historian-append.sh
  historian-legacy-copy.sh
  historian-staging-run-append.sh
  historian-integrity-monitor.sh
  historian-staleness-monitor.sh
  historian-cutover-coverage-check.sh
  historian-ee-coverage-check.sh
)
for s in "${SCRIPTS[@]}"; do
  install -m 0755 "$REPO_ROOT/scripts/$s" "$DEST/$s"
done

# ── 2. SQL (post-run stamp + boundary refresh; read by the full wrapper) ──────
install -m 0644 "$REPO_ROOT/scripts/stamp-equipment_values-meta.sql"                    "$DEST/stamp-equipment_values-meta.sql"
install -m 0644 "$REPO_ROOT/services/historian-gateway/refresh-equipment_values-cutover.sql" "$DEST/refresh-equipment_values-cutover.sql"
install -m 0644 "$REPO_ROOT/services/historian-gateway/refresh-ee-cutover.sql"          "$DEST/refresh-ee-cutover.sql"

# ── 3. remove superseded artifacts (orphan wrapper + pre-#281 SQL file names) ─
for stale in run-staging-append.sh stamp-hist-meta.sql refresh-hist-cutover.sql; do
  if [ -e "$DEST/$stale" ]; then
    echo "[install-historian] removing superseded $DEST/$stale"
    rm -f "$DEST/$stale"
  fi
done

# ── 4. systemd units (append + integrity-monitor, each .service + .timer) ─────
UNITS=(
  historian-staging-append.service   historian-staging-append.timer
  historian-integrity-monitor.service historian-integrity-monitor.timer
)
for u in "${UNITS[@]}"; do
  install -m 0644 "$REPO_ROOT/systemd/$u" "$UNIT_DIR/$u"
done

# ── 5. reload + enable the timers (idempotent) ────────────────────────────────
systemctl daemon-reload
systemctl enable --now historian-staging-append.timer historian-integrity-monitor.timer

# ── 6. summary + drift assertion ──────────────────────────────────────────────
EXECSTART="$(systemctl cat historian-staging-append.service | awk -F= '/^ExecStart=/{print $2}')"
echo "[install-historian] installed. timer ExecStart=$EXECSTART"
case "$EXECSTART" in
  */historian-staging-run-append.sh) echo "[install-historian] OK: timer runs the FULL wrapper (append+stamp+refresh)";;
  *) echo "[install-historian] WARNING: ExecStart is not the full wrapper — check systemd/historian-staging-append.service" >&2;;
esac
systemctl list-timers historian-staging-append.timer historian-integrity-monitor.timer --no-pager 2>/dev/null | head -4 || true
echo "[install-historian] done."
