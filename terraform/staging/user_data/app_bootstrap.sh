#!/bin/bash
# Minimal EC2 user_data — stays well under the 16 KB AWS limit.
# Downloads the full init script from S3 and executes it.
#
# EIP association happens after instance launch — the instance has no internet
# access until the EIP is attached. We retry until S3 is reachable.
set -euo pipefail

# Cloud-init runs with a minimal PATH — extend it so aws CLI and dnf are found.
export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"

LOG=/var/log/packiot-bootstrap.log
log() { echo "[bootstrap $(date -u +%T)] $*" | tee -a "$LOG" >> /dev/console 2>/dev/null || true; }

log "=== Packiot App bootstrap starting ==="

# ── Diagnose IMDSv2 ──────────────────────────────────────────────────────────
TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  IMDSIID=$(curl -sf http://169.254.169.254/latest/meta-data/instance-id \
    -H "X-aws-ec2-metadata-token: $TOKEN" 2>/dev/null || echo "unknown")
  log "IMDS v2 OK — instance-id: $IMDSIID"
else
  log "WARNING: IMDSv2 token request failed — IMDS may be unreachable"
fi

# ── Wait for internet (EIP association may still be in progress) ─────────────
until curl -sf --connect-timeout 5 https://aws.amazon.com/ > /dev/null 2>&1; do
  log "Waiting for internet (EIP association may still be in progress)..."
  sleep 5
done
log "Internet reachable"

# ── Wait for S3 access via IAM (IMDS must serve credentials) ─────────────────
until aws s3 ls "s3://${state_bucket}/scripts/" --region ${aws_region} > /dev/null 2>&1; do
  log "Waiting for S3 IAM access (IMDS credentials may not be ready)..."
  sleep 5
done
log "S3 accessible via IAM"

# ── Install + start SSM agent early (NOT pre-installed on AL2023 arm64) ──────
dnf install -y amazon-ssm-agent 2>&1 | tee -a "$LOG" >> /dev/console 2>/dev/null || true
systemctl enable amazon-ssm-agent 2>&1 | tee -a "$LOG" >> /dev/console 2>/dev/null || true
systemctl start  amazon-ssm-agent 2>&1 | tee -a "$LOG" >> /dev/console 2>/dev/null || true
log "SSM agent installed and started"

# ── Download and exec full init script ───────────────────────────────────────
aws s3 cp "s3://${state_bucket}/scripts/app_init.sh" /opt/packiot-app-init.sh \
    --region ${aws_region}
chmod +x /opt/packiot-app-init.sh
log "Handing off to app_init.sh"
exec /opt/packiot-app-init.sh
