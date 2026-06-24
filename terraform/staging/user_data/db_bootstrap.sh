#!/bin/bash
# Minimal EC2 user_data for the DB EC2 — stays well under the 16 KB AWS limit.
# Downloads the full init script from S3 and executes it.
#
# The DB EC2 is in a private subnet; outbound internet flows through the NAT
# gateway, which is available as soon as the route table converges. We retry
# on internet + S3 readiness rather than racing them.
set -euo pipefail

# Cloud-init runs with a minimal PATH — extend it so aws CLI and dnf are found.
export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"

LOG=/var/log/packiot-db-bootstrap.log
log() { echo "[db-bootstrap $(date -u +%T)] $*" | tee -a "$LOG" >> /dev/console 2>/dev/null || true; }

log "=== Packiot DB bootstrap starting ==="

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

# ── Wait for internet via NAT gateway ────────────────────────────────────────
until curl -sf --connect-timeout 5 https://aws.amazon.com/ > /dev/null 2>&1; do
  log "Waiting for internet (NAT gateway route may still be converging)..."
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
aws s3 cp "s3://${state_bucket}/scripts/db_init.sh" /opt/packiot-db-init.sh \
    --region ${aws_region}
chmod +x /opt/packiot-db-init.sh
log "Handing off to db_init.sh"
exec /opt/packiot-db-init.sh
