#!/bin/bash
# ── Self-hosted org CI runner bootstrap ───────────────────────────────────────
# Runs once on first boot via EC2 user_data (rendered by templatefile in
# ci_runner.tf; shell vars are escaped $${LIKE_THIS}, Terraform template vars
# are $${plain}). Logs to /var/log/packiot-ci-runner-init.log.
#
# What it does, in order:
#   1. Install prerequisites (git, jq, gcc/build tools for node-gyp, Docker, the
#      actions-runner's own deps via bin/installdependencies.sh).
#   2. Create a dedicated NON-ROOT `runner` user + install the pinned runner
#      under it.
#   3. Drop /opt/packiot/register-ci-runner.sh — the (re-)registration helper.
#      It fetches the PAT from Secrets Manager, exchanges it for a short-lived
#      ORG registration token, and registers at ORG scope. Fail-closed: if the
#      PAT is missing/placeholder it exits non-zero with a clear message.
#   4. Install the runner as a systemd service (survives reboot) running as the
#      non-root `runner` user, then call the helper once.
#
# Idempotent: safe to re-run (the helper stops/uninstalls any prior service and
# re-registers with --replace). If the PAT is not yet set, boot still completes
# (the box stays up + SSM-reachable) — you SSM in and run the helper after
# populating the secret. See docs/ci-selfhosted-runner-runbook.md.
set -euo pipefail
exec > >(tee /var/log/packiot-ci-runner-init.log | logger -t packiot-ci-runner) 2>&1

export HOME=/root
export PATH="/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin:/bin:$PATH"

echo "=== Packiot CI runner init starting $(date -u) ==="

AWS_REGION="${aws_region}"
GITHUB_ORG="${github_org}"
RUNNER_VERSION="${runner_version}"
RUNNER_LABELS="${runner_labels}"
RUNNER_EPHEMERAL="${runner_ephemeral}"
PAT_SECRET_ID="${pat_secret_id}"
RUNNER_HOME="/opt/actions-runner"
RUNNER_USER="runner"

# ── SSM agent — the ONLY access path (no SSH ingress). Install + start first so
# the box is reachable even if a later step fails. ────────────────────────────
dnf install -y amazon-ssm-agent || true
systemctl enable amazon-ssm-agent || true
systemctl start  amazon-ssm-agent || true

# ── System prerequisites ──────────────────────────────────────────────────────
# AL2023 ships curl-minimal which conflicts with curl; --allowerasing lets dnf
# replace it. build tools (gcc/make) are needed by node-gyp native npm deps;
# libicu is required by the .NET runtime embedded in the actions-runner.
dnf update -y --allowerasing
dnf install -y git curl jq tar unzip gcc gcc-c++ make libicu --allowerasing

# ── Docker (many CI jobs build/run containers) ────────────────────────────────
dnf install -y docker
systemctl enable docker
systemctl start  docker

# ── Swap — front4's Vite/tsc build is memory-hungry; a 4 GB box + 4 GB swap
# absorbs the peak so the OOM killer doesn't reap the runner mid-build. ─────────
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
fi
swapon /swapfile 2>/dev/null || true
grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab

# ── Dedicated non-root runner user ────────────────────────────────────────────
# The runner must NOT run as root (a compromised job would own the box). It IS
# added to the docker group so jobs can build/run containers — note this is
# effectively root-equivalent via the Docker socket, an accepted trade-off for a
# private-repo-only CI box (documented in the runbook's security section).
if ! id "$RUNNER_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$RUNNER_USER"
fi
usermod -aG docker "$RUNNER_USER"

# ── Install the pinned actions-runner under the runner user ───────────────────
mkdir -p "$RUNNER_HOME"
if [ ! -f "$RUNNER_HOME/config.sh" ]; then
  curl -sSL -o /tmp/actions-runner.tar.gz \
    "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz"
  tar xzf /tmp/actions-runner.tar.gz -C "$RUNNER_HOME"
  rm -f /tmp/actions-runner.tar.gz
fi
chown -R "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_HOME"

# actions-runner's own OS deps (installs as root, one-time).
"$RUNNER_HOME/bin/installdependencies.sh"

# ── (Re-)registration helper — re-runnable for rotation / re-provision ────────
# Written with a quoted heredoc so NO shell expansion happens here; the template
# vars it needs are baked in as literals at render time.
cat > /opt/packiot/register-ci-runner.sh <<REGSCRIPT
#!/bin/bash
# Register (or re-register) this box as an ORG-scoped self-hosted runner.
# Idempotent + fail-closed. Run via: sudo /opt/packiot/register-ci-runner.sh
set -euo pipefail

AWS_REGION="${aws_region}"
GITHUB_ORG="${github_org}"
PAT_SECRET_ID="${pat_secret_id}"
RUNNER_LABELS="${runner_labels}"
RUNNER_EPHEMERAL="${runner_ephemeral}"
RUNNER_HOME="/opt/actions-runner"
RUNNER_USER="runner"

# --- Fetch the PAT (fail-closed) -------------------------------------------------
PAT=\$(aws secretsmanager get-secret-value \
  --secret-id "\$PAT_SECRET_ID" --region "\$AWS_REGION" \
  --query SecretString --output text 2>/dev/null | jq -r '.pat // empty')

if [ -z "\$PAT" ] || [ "\$PAT" = "REPLACE_ME_WITH_ORG_PAT" ]; then
  echo "FATAL: PAT secret '\$PAT_SECRET_ID' is missing or still the placeholder." >&2
  echo "       Populate it (runbook §1) then re-run: sudo /opt/packiot/register-ci-runner.sh" >&2
  exit 1
fi

# --- Exchange the PAT for a short-lived (1h) ORG registration token --------------
REG_TOKEN=\$(curl -sf -X POST \
  -H "Authorization: Bearer \$PAT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/orgs/\$GITHUB_ORG/actions/runners/registration-token" \
  | jq -r '.token')

if [ -z "\$REG_TOKEN" ] || [ "\$REG_TOKEN" = "null" ]; then
  echo "FATAL: could not obtain an org registration token — check the PAT scope" >&2
  echo "       (needs manage_runners:org / classic admin:org) and org name '\$GITHUB_ORG'." >&2
  exit 1
fi

cd "\$RUNNER_HOME"

# --- Idempotent: tear down any prior service before re-registering --------------
if [ -f "\$RUNNER_HOME/.service" ]; then
  ./svc.sh stop      || true
  ./svc.sh uninstall || true
fi
# Remove a stale runner config so config.sh doesn't refuse (runner user context).
if [ -f "\$RUNNER_HOME/.runner" ]; then
  sudo -u "\$RUNNER_USER" ./config.sh remove --token "\$REG_TOKEN" || true
fi

EPHEMERAL_FLAG=""
[ "\$RUNNER_EPHEMERAL" = "true" ] && EPHEMERAL_FLAG="--ephemeral"

# --- Register at ORG scope as the NON-ROOT runner user --------------------------
sudo -u "\$RUNNER_USER" ./config.sh \
  --url "https://github.com/\$GITHUB_ORG" \
  --token "\$REG_TOKEN" \
  --name "packiot-ci-\$(hostname)" \
  --labels "\$RUNNER_LABELS" \
  --unattended \
  --replace \
  \$EPHEMERAL_FLAG

# --- Install + start the systemd service (runs AS the runner user) --------------
./svc.sh install "\$RUNNER_USER"
./svc.sh start

echo "CI runner registered at org scope (labels: \$RUNNER_LABELS) and service started."
echo "Verify 'Idle' at: https://github.com/organizations/\$GITHUB_ORG/settings/actions/runners"
REGSCRIPT
chmod +x /opt/packiot/register-ci-runner.sh

# ── Register now (non-fatal to boot: if the PAT isn't set yet, the box still
# comes up SSM-reachable so an operator can populate it and re-run the helper). ─
mkdir -p /opt/packiot
if /opt/packiot/register-ci-runner.sh; then
  echo "=== CI runner bootstrap complete + registered $(date -u) ==="
else
  echo "=== CI runner bootstrap complete but NOT registered (PAT not set?) — SSM in and run: sudo /opt/packiot/register-ci-runner.sh ==="
fi
