#!/bin/bash
# EC2 user_data — self-hosted GitHub Actions runner(s) for the packiot org (task #57).
#
# WHY THIS EXISTS: every workflow across the org ran on `ubuntu-latest`. The org is
# on the GitHub Free plan and hits the Actions minutes/billing cap → jobs die in
# ~2s with "no runner assigned" and no logs, so CI AND the deploy pipelines are
# all dead. This box hosts self-hosted runner(s) that escape that cap.
#
# ⚠ GITHUB FREE-PLAN CONSTRAINT (proven 2026-08-12): ORG-level self-hosted runners
# do NOT get jobs dispatched to PRIVATE repos on the Free plan — the runner shows
# online but sits idle forever. So we register **REPO-level** runners, one per
# repo that needs CI, each in its own directory + service. One box, N instances.
# (Org-level for private repos would need GitHub Team/Enterprise.)
#
# ARCH: arm64 (t4g/Graviton) — matches the stack, builds the arm64 images prod runs.
#
# AUTH: reads a GitHub PAT (repo + admin:org) from Secrets Manager, mints a
# short-lived per-repo registration token, registers unattended (--replace). PAT
# is populated out-of-band (never in git). Re-registration on replacement is
# automatic → a fresh instance comes up FULLY ready (toolchain + all runners).
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"

LOG=/var/log/packiot-runner-bootstrap.log
log() { echo "[runner-boot $(date -u +%T)] $*" | tee -a "$LOG" >> /dev/console 2>/dev/null || true; }
log "=== Packiot self-hosted runner(s) bootstrap starting ==="

ORG="${github_org}"
SECRET_ID="${runner_pat_secret_id}"
AWS_REGION="${aws_region}"
RUNNER_VERSION="${runner_version}"
LABELS="${runner_labels}"
REPOS="${runner_repos}" # comma-separated repo names under the org, e.g. "edge-api,csadmin"

# ── Wait for internet ─────────────────────────────────────────────────────────
until curl -sf --connect-timeout 5 https://api.github.com > /dev/null 2>&1; do
  log "Waiting for internet…"; sleep 5
done
log "Internet reachable"

# ── Toolchain: a bare AL2023 box lacks what ubuntu-latest ships pre-installed.
#    Install the general CI toolchain so Node/Go/make/docker jobs run without a
#    per-workflow setup step (the existing workflows assume these are present). ──
dnf install -y docker git tar gzip jq libicu \
  nodejs npm make gcc gcc-c++ golang findutils which >> "$LOG" 2>&1
systemctl enable --now docker
log "Toolchain: node=$(node -v 2>/dev/null) go=$(go version 2>/dev/null | awk '{print $3}') docker ok"

# ── Dedicated non-root runner user ───────────────────────────────────────────
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
usermod -aG docker runner

# ── PAT (repo + admin:org) — mints per-repo registration tokens ──────────────
PAT=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
        --region "$AWS_REGION" --query SecretString --output text 2>/dev/null \
      | jq -r '.pat // empty')
if [ -z "$PAT" ] || [ "$PAT" = "REPLACE_ME_OUT_OF_BAND" ]; then
  log "FATAL: no usable PAT in $SECRET_ID — populate {\"pat\":\"<repo+admin:org token>\"} then replace this instance"
  exit 1
fi

INSTANCE_ID=$(curl -fsSL -H "X-aws-ec2-metadata-token: $(curl -sf -X PUT \
  http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" \
  http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "unknown")

# ── One repo-level runner instance per repo, each in its own dir + service ────
IFS=',' read -ra REPO_ARR <<< "$REPOS"
for REPO in "$${REPO_ARR[@]}"; do
  REPO=$(echo "$REPO" | tr -d ' ')
  [ -n "$REPO" ] || continue
  DIR="/home/runner/$${REPO}"
  log "Setting up runner for repo '$${REPO}' in $${DIR}"
  mkdir -p "$DIR"

  if [ ! -f "$${DIR}/config.sh" ]; then
    curl -fsSL -o "$${DIR}/runner.tar.gz" \
      "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/actions-runner-linux-arm64-$${RUNNER_VERSION}.tar.gz"
    tar xzf "$${DIR}/runner.tar.gz" -C "$DIR" && rm -f "$${DIR}/runner.tar.gz"
  fi
  chown -R runner:runner "$DIR"

  REG_TOKEN=$(curl -fsSL -X POST \
    -H "Authorization: Bearer $PAT" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$${ORG}/$${REPO}/actions/runners/registration-token" | jq -r .token)
  if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    log "WARN: could not mint registration token for $${REPO} (PAT repo scope?) — skipping"
    continue
  fi

  ( cd "$DIR" && sudo -u runner ./config.sh \
      --url "https://github.com/$${ORG}/$${REPO}" \
      --token "$REG_TOKEN" \
      --name "packiot-ci-$${REPO}-$${INSTANCE_ID}" \
      --labels "$${LABELS}" \
      --work _work --unattended --replace >> "$LOG" 2>&1
    ./svc.sh install runner >> "$LOG" 2>&1
    ./svc.sh start >> "$LOG" 2>&1 )
  log "Runner for '$${REPO}' registered + started (labels: $${LABELS})"
done
unset PAT
log "=== All repo runners up ==="
