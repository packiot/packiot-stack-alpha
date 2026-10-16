#!/bin/bash
# install-historian-backup.sh — one-shot install of the historian backup on the APP box
#
# Installs backup-db.sh / restore-db.sh / backup-historian.sh into
# /opt/packiot/scripts, the packiot-historian-backup.{service,timer} units and
# /etc/packiot/historian-backup.env, then enables the timer. Idempotent.
# Replaced files are kept as <file>.bak-<date>.
#
# MODE=target needs the app role's backup grant (terraform/staging/backups.tf,
# aws_iam_role_policy.app_backup_ops). Metrics reach Prometheus through
# node-exporter's textfile collector (compose.staging.yml).
#
#   HISTORIAN_BUCKET=packiot-staging-historian-<acct> ./install-historian-backup.sh              # interim
#   MODE=target BACKUP_BUCKET=packiot-staging-db-backups-<acct> HISTORIAN_BUCKET=... ./install-historian-backup.sh
set -euo pipefail
: "${REPO_PATH:=$(cd "$(dirname "$0")" && pwd)}"
: "${HISTORIAN_BUCKET:?HISTORIAN_BUCKET required (packiot-staging-historian-<acct>)}"
: "${AWS_REGION:=us-east-1}"
stamp=$(date -u +%Y%m%d)

mkdir -p /opt/packiot/scripts /etc/packiot /var/lib/packiot-backup/metrics
for f in backup-db.sh restore-db.sh backup-historian.sh; do
    dst=/opt/packiot/scripts/$f
    if [ -f "$dst" ] && ! cmp -s "$REPO_PATH/$f" "$dst"; then cp -a "$dst" "$dst.bak-$stamp"; fi
    install -m 0755 "$REPO_PATH/$f" "$dst"
done
install -m 0644 "$REPO_PATH/packiot-historian-backup.service" /etc/systemd/system/
install -m 0644 "$REPO_PATH/packiot-historian-backup.timer"   /etc/systemd/system/

# MODE=interim (default): catalog dumps into the historian bucket under _backup/,
# no Parquet mirror — the only S3 the app role can write today.
# MODE=target: after aws_iam_role_policy.app_backup_ops (backups.tf) is applied.
: "${MODE:=interim}"
[ -f /etc/packiot/historian-backup.env ] && cp -a /etc/packiot/historian-backup.env "/etc/packiot/historian-backup.env.bak-$stamp"
if [ "$MODE" = target ]; then
    : "${BACKUP_BUCKET:?BACKUP_BUCKET required for MODE=target}"
    TGT_BUCKET=$BACKUP_BUCKET; KEYP=""; PRUNE=0; MIRROR_TO="s3://$BACKUP_BUCKET/historian-parquet/"
else
    TGT_BUCKET=$HISTORIAN_BUCKET; KEYP="_backup/"; PRUNE=1; MIRROR_TO=""
fi
cat > /etc/packiot/historian-backup.env <<ENV
# written by install-historian-backup.sh MODE=$MODE
BACKUP_BUCKET=$TGT_BUCKET
BACKUP_KEY_PREFIX=$KEYP
PRUNE=$PRUNE
MIRROR_TO=$MIRROR_TO
HISTORIAN_BUCKET=$HISTORIAN_BUCKET
AWS_REGION=$AWS_REGION
GATEWAY_CONTAINER=hist-gateway
METRICS_DIR=/var/lib/packiot-backup/metrics
RETAIN_DAILY=14
RETAIN_WEEKLY=4
RETAIN_MONTHLY=3
ENV
chmod 0644 /etc/packiot/historian-backup.env

systemctl daemon-reload
systemctl enable --now packiot-historian-backup.timer
echo "installed; next run: $(systemctl show -p NextElapseUSecRealtime --value packiot-historian-backup.timer)"
echo "run now: systemctl start packiot-historian-backup.service && journalctl -u packiot-historian-backup -n 50"
