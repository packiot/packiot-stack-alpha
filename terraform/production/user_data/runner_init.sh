#!/bin/bash
# EC2 user_data — self-hosted GitHub Actions runner for the packiot org.
#
# WHY THIS EXISTS (task #57): every workflow across the org runs on
# `ubuntu-latest` (GitHub-hosted). The org is on the Free plan and hits the
# Actions minutes/billing cap → every job dies in ~2s with "no runner assigned"
# and no logs, so CI AND the deploy pipelines are all dead. This box is a
# persistent org-level self-hosted runner that escapes that cap.
#
# ARCH: arm64 (t4g / Graviton) — this MATCHES the stack (app/db/superset are all
# t4g/r7g Graviton), so the Docker images it builds are the arm64 images prod
# actually runs. Do NOT move to x64 without a reason.
#
# AUTH: reads a GitHub PAT (scope: admin:org → manage_runners) from Secrets
# Manager at boot, mints a short-lived org registration token, and registers
# unattended. The PAT is populated out-of-band (never in git/terraform); see
# github_runner.tf. Re-registration on replacement is automatic (--replace).
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"

LOG=/var/log/packiot-runner-bootstrap.log
log() { echo "[runner-boot $(date -u +%T)] $*" | tee -a "$LOG" >> /dev/console 2>/dev/null || true; }
log "=== Packiot self-hosted runner bootstrap starting ==="

ORG="${github_org}"
SECRET_ID="${runner_pat_secret_id}"
AWS_REGION="${aws_region}"
RUNNER_VERSION="${runner_version}"
LABELS="${runner_labels}"

# ── Wait for internet (public IP association can lag first boot) ──────────────
until curl -sf --connect-timeout 5 https://api.github.com > /dev/null 2>&1; do
  log "Waiting for internet…"; sleep 5
done
log "Internet reachable"

# ── Base packages + Docker (arm64) ───────────────────────────────────────────
dnf install -y docker git jq tar gzip libicu >> "$LOG" 2>&1
systemctl enable --now docker
log "Docker installed"

# ── Dedicated non-root runner user (never run the runner as root) ────────────
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
usermod -aG docker runner
RUNNER_HOME=/home/runner/actions-runner
mkdir -p "$RUNNER_HOME"

# ── Fetch the arm64 runner tarball ───────────────────────────────────────────
cd "$RUNNER_HOME"
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/actions-runner-linux-arm64-$${RUNNER_VERSION}.tar.gz"
tar xzf runner.tar.gz && rm -f runner.tar.gz
chown -R runner:runner /home/runner
log "Runner $${RUNNER_VERSION} unpacked"

# ── Mint an org registration token from the PAT (Secrets Manager) ────────────
PAT=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
        --region "$AWS_REGION" --query SecretString --output text 2>/dev/null \
      | jq -r '.pat // empty')
if [ -z "$PAT" ]; then
  log "FATAL: no PAT in secret $SECRET_ID — populate it with {\"pat\":\"<admin:org token>\"} then reboot"
  exit 1
fi
REG_TOKEN=$(curl -fsSL -X POST \
  -H "Authorization: Bearer $PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/$${ORG}/actions/runners/registration-token" | jq -r .token)
unset PAT
if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
  log "FATAL: could not mint registration token (check PAT scope: admin:org)"; exit 1
fi
log "Registration token minted"

# ── Configure + install as a service (unattended, --replace for re-boot) ─────
INSTANCE_ID=$(curl -fsSL -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
  http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")

sudo -u runner ./config.sh \
  --url "https://github.com/$${ORG}" \
  --token "$REG_TOKEN" \
  --name "prod-runner-$${INSTANCE_ID}" \
  --labels "$${LABELS}" \
  --work _work \
  --unattended --replace >> "$LOG" 2>&1
unset REG_TOKEN

./svc.sh install runner >> "$LOG" 2>&1
./svc.sh start >> "$LOG" 2>&1
log "=== Runner registered + service started (labels: $${LABELS}) ==="
