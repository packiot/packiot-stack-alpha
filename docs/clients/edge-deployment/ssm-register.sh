#!/usr/bin/env bash
# ssm-register.sh — first-boot enrollment of THIS factory box as an AWS SSM
# managed instance (ADR-0049: SSM as the edge connectivity/access/deploy
# substrate). SUPERSEDES register-runner.sh (ADR-0005 GitHub runner) for the
# new-stack edge.
#
# WHAT THIS DOES
#   Installs the amazon-ssm-agent (a small open-source Go binary — runs on
#   EOL Ubuntu 18.04 where the .NET-8 GitHub runner cannot) and registers this
#   box against a Hybrid Activation minted by CS-Admin (edge-api
#   POST /api/edge-ssm/activation). After this the box appears in AWS as a
#   `mi-xxxx` managed instance tagged `client=<slug>` and CS-Admin can push
#   deploys via RunCommand + reach it via Session Manager — all OUTBOUND 443
#   only, ZERO inbound firewall holes (same property as the :8883 mTLS uplink).
#
# HANDOFF (mirror of the mTLS-key discipline)
#   The activation code/id/region are minted per-box and handed off through the
#   SAME secure channel as the mTLS client key — NEVER committed. They live in a
#   gitignored env file (default /opt/packiot/edge-ssm.env, see
#   edge-ssm.env.example) that the generator fills; the systemd oneshot
#   (ssm-register.service) loads it via EnvironmentFile. The activation CODE is
#   shown ONCE by AWS at mint time.
#
# IDEMPOTENT
#   Skips cleanly if this box is already registered
#   (/var/lib/amazon/ssm/registration present) — safe to run on every boot.
#
# USAGE (manual)
#   SSM_ACTIVATION_CODE=… SSM_ACTIVATION_ID=… SSM_REGION=us-east-1 \
#     sudo ./ssm-register.sh
#   …or drop the three values into /opt/packiot/edge-ssm.env and run
#   `sudo systemctl start ssm-register.service`.
set -euo pipefail

# ── config (env-driven; the systemd unit supplies these via EnvironmentFile) ──
SSM_ENV_FILE="${SSM_ENV_FILE:-/opt/packiot/edge-ssm.env}"
# Best-effort source of a local env file for manual runs (systemd already loads
# it). Only sets vars that are not already in the environment.
if [ -f "$SSM_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  set -a; . "$SSM_ENV_FILE"; set +a
fi

SSM_REGION="${SSM_REGION:-us-east-1}"
REGISTRATION_MARKER="/var/lib/amazon/ssm/registration"
DEB_BASE="https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest"

# ── privilege helper: install/register needs root ─────────────────────────────
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 || { echo "must run as root (or install sudo)" >&2; exit 1; }
  SUDO="sudo"
fi

log() { echo "ssm-register: $*"; }

# ── 0. IDEMPOTENT short-circuit ───────────────────────────────────────────────
# If already registered, just make sure the agent is up and exit 0. This lets
# the oneshot run on every boot with no side effects (ADR-0049 C4: the on-box
# component must be small + self-healing).
if [ -f "$REGISTRATION_MARKER" ]; then
  log "already registered ($REGISTRATION_MARKER present) — ensuring agent is enabled"
  $SUDO systemctl enable --now amazon-ssm-agent 2>/dev/null \
    || $SUDO snap start amazon-ssm-agent 2>/dev/null \
    || true
  exit 0
fi

# ── 1. Require the activation credential ──────────────────────────────────────
: "${SSM_ACTIVATION_CODE:?set SSM_ACTIVATION_CODE (minted by CS-Admin; shown once)}"
: "${SSM_ACTIVATION_ID:?set SSM_ACTIVATION_ID (minted by CS-Admin)}"

# ── 2. Install amazon-ssm-agent if absent ─────────────────────────────────────
# Preferred path: the .deb from S3 — works on modern Ubuntu AND on CPACK's real
# box, EOL Ubuntu 18.04 (validate on-box, but the current agent supports it).
# The .deb auto-installs the `amazon-ssm-agent` systemd unit. snap is the
# fallback for hosts where dpkg is unavailable.
install_agent() {
  if command -v amazon-ssm-agent >/dev/null 2>&1 \
     || [ -x /usr/bin/amazon-ssm-agent ] \
     || [ -x /snap/bin/amazon-ssm-agent ]; then
    log "amazon-ssm-agent already installed"
    return 0
  fi

  case "$(uname -m)" in
    x86_64|amd64)  DEB_ARCH="debian_amd64" ;;
    aarch64|arm64) DEB_ARCH="debian_arm64" ;;
    *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac

  if command -v dpkg >/dev/null 2>&1; then
    local tmp; tmp="$(mktemp -d)"
    log "downloading amazon-ssm-agent.deb ($DEB_ARCH)…"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$tmp/ssm.deb" "$DEB_BASE/$DEB_ARCH/amazon-ssm-agent.deb"
    else
      wget -qO "$tmp/ssm.deb" "$DEB_BASE/$DEB_ARCH/amazon-ssm-agent.deb"
    fi
    # -E preserves env; the .deb registers + installs the systemd unit.
    $SUDO dpkg -i "$tmp/ssm.deb"
    rm -rf "$tmp"
  elif command -v snap >/dev/null 2>&1; then
    log "dpkg absent — installing via snap"
    $SUDO snap install amazon-ssm-agent --classic
  else
    echo "no dpkg and no snap — cannot install amazon-ssm-agent" >&2
    exit 1
  fi
}
install_agent

# ── 3. Stop the agent before -register (AWS requires it idle) ─────────────────
$SUDO systemctl stop amazon-ssm-agent 2>/dev/null \
  || $SUDO snap stop amazon-ssm-agent 2>/dev/null \
  || true

# Resolve the agent binary path (deb vs snap).
AGENT_BIN="$(command -v amazon-ssm-agent 2>/dev/null || true)"
[ -n "$AGENT_BIN" ] || AGENT_BIN="/usr/bin/amazon-ssm-agent"
[ -x "$AGENT_BIN" ] || AGENT_BIN="/snap/bin/amazon-ssm-agent"

# ── 4. Register against the Hybrid Activation (outbound 443) ───────────────────
log "registering managed instance in $SSM_REGION…"
$SUDO "$AGENT_BIN" -register \
  -code "$SSM_ACTIVATION_CODE" \
  -id "$SSM_ACTIVATION_ID" \
  -region "$SSM_REGION" \
  -y

# ── 5. Enable + start the agent (survives reboots / power-cycles) ─────────────
$SUDO systemctl enable --now amazon-ssm-agent 2>/dev/null \
  || $SUDO snap start amazon-ssm-agent 2>/dev/null \
  || true

log "done — this box should now appear as a mi-xxxx managed instance."
log "verify from the control plane: GET /api/edge-ssm/status?clientSlug=<slug>"
