#!/usr/bin/env bash
# install-cold-export.sh <staging|production> — install ONLY the ADR-0065 P1 cold exporter (script + unit + timer)
# with the environment's settings as a systemd drop-in. Idempotent; the production deploy runs it every time.
#
# Staging gets the exporter from install-historian-pipeline.sh (together with the legacy-append pipeline, which
# production must NOT run); this script is for hosts that need the exporter alone. What it does NOT do: shorten any
# hot window. Production keeps raw retention off (ops.retention_policy.keep NULL) until P4 is decided there; the
# exporter only fills the verified manifest that a later P4 drop gate reads.
#
#   sudo bash scripts/ops/install-cold-export.sh production
set -euo pipefail
ENVNAME="${1:?usage: install-cold-export.sh <staging|production>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST=/opt/packiot/historian
UNIT_DIR=/etc/systemd/system
ACCOUNT=639178078294
case "$ENVNAME" in
  production) BUCKET="packiot-production-historian-${ACCOUNT}"; AN_DB=packiot ;;
  staging)    BUCKET="packiot-staging-historian-${ACCOUNT}";    AN_DB=packiot_analytics ;;
  *) echo "unknown env $ENVNAME" >&2; exit 2 ;;
esac
echo "[install-cold-export] env=$ENVNAME bucket=$BUCKET db=$AN_DB"
install -d -m 0755 "$DEST"
install -m 0755 "$REPO_ROOT/scripts/historian-cold-export.sh" "$DEST/historian-cold-export.sh"
# the exporter's post-run gateway hook skips itself when no hist-gateway container runs (production today)
install -m 0644 "$REPO_ROOT/services/historian-gateway/refresh-f3-cutover.sql" "$DEST/refresh-f3-cutover.sql"
install -m 0644 "$REPO_ROOT/systemd/historian-cold-export.service" "$UNIT_DIR/historian-cold-export.service"
install -m 0644 "$REPO_ROOT/systemd/historian-cold-export.timer"   "$UNIT_DIR/historian-cold-export.timer"
install -d -m 0755 "$UNIT_DIR/historian-cold-export.service.d"
cat > "$UNIT_DIR/historian-cold-export.service.d/10-env.conf" <<CONF
# written by scripts/ops/install-cold-export.sh $ENVNAME — no secrets here (the DB password is read from
# /opt/packiot/.env by the script itself; S3 uses the instance role)
[Service]
Environment=HISTORIAN_BUCKET=$BUCKET
Environment=AN_DB=$AN_DB
CONF
systemctl daemon-reload
systemctl enable --now historian-cold-export.timer
systemctl list-timers historian-cold-export.timer --no-pager | head -2
