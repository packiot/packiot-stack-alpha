#!/usr/bin/env bash
# ⚠️ SUPERSEDED (ADR-0049, 2026-08-27) — DO NOT USE FOR THE NEW-STACK EDGE.
#   The per-factory GitHub self-hosted runner (ADR-0005) is replaced by AWS SSM
#   RunCommand as the deploy substrate: the box enrolls via `ssm-register.sh`
#   (a Hybrid Activation) and CS-Admin pushes deploys through edge-api
#   (POST /api/edge-ssm/deploy → ssm:SendCommand). SSM clears the constraints
#   this script cannot: it runs on EOL Ubuntu 18.04 where the .NET-8 runner
#   cannot (ADR-0049 C1), and carries only IAM-scoped, audited operations
#   instead of arbitrary workflow code in the plant network (C5).
#   Kept (not deleted) as break-glass / historical reference per the
#   clean-abandoned-path-trails rule — a permanent delete is a human decision.
#   New edge boxes: use `ssm-register.sh` + `ssm-register.service` instead.
#
# register-runner.sh — one-time: register THIS factory box as the GitHub
# self-hosted runner the "Client Edge Deploy" workflow targets (ADR-0005).
#
# WHAT THIS DOES
#   The Client Edge Deploy workflow runs `runs-on: [self-hosted, <client>]`, so
#   the deploy lands on whichever machine is registered with that label. Run this
#   ONCE on the Linux box at the client factory (the one that can reach the PLCs
#   and has Docker) to create that runner. After this, the GitHub Action can
#   deploy the Node-RED + agent bundle onto this box.
#
# PREREQUISITES ON THIS BOX
#   - Linux (amd64 or arm64), Docker + Compose v2 installed, curl + tar.
#   - Outbound HTTPS to github.com (the runner long-polls GitHub; no inbound).
#   - A registration credential (one of the two below).
#
# USAGE
#   CLIENT=cpack GH_RUNNER_TOKEN=<reg-token> ./register-runner.sh
#     — the simplest path: mint a short-lived registration token yourself from
#       GitHub → repo Settings → Actions → Runners → "New self-hosted runner"
#       (it's shown in the config.sh line), paste it here.
#
#   CLIENT=cpack GH_PAT=<pat> ./register-runner.sh
#     — CI/automation path: pass a PAT (repo admin scope) and the script mints the
#       registration token itself. The PAT for this repo lives in AWS Secrets
#       Manager at packiot/production/github-runner (.pat) — retrieve it out of
#       band; NEVER commit it or bake it into this box's history.
#
# ENV (optional)
#   REPO           default: packiot/packiot-stack-alpha
#   RUNNER_VERSION default: 2.319.1
#   RUNNER_NAME    default: <CLIENT>-edge-$(hostname)
#   RUNNER_DIR     default: $HOME/actions-runner-<CLIENT>
set -euo pipefail

CLIENT="${CLIENT:?set CLIENT to the client slug (e.g. cpack) — MUST match the workflow input + bundle dir}"
REPO="${REPO:-packiot/packiot-stack-alpha}"
RUNNER_VERSION="${RUNNER_VERSION:-2.319.1}"
RUNNER_NAME="${RUNNER_NAME:-${CLIENT}-edge-$(hostname -s 2>/dev/null || echo host)}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner-${CLIENT}}"

# ── pick CPU arch for the runner tarball ──────────────────────────────────────
case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# ── resolve a registration token (from GH_RUNNER_TOKEN, or mint via GH_PAT) ────
if [ -n "${GH_RUNNER_TOKEN:-}" ]; then
  REG_TOKEN="$GH_RUNNER_TOKEN"
elif [ -n "${GH_PAT:-}" ]; then
  echo "minting a runner registration token via the PAT…"
  REG_TOKEN="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${GH_PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/actions/runners/registration-token" \
    | grep -o '"token":[[:space:]]*"[^"]*"' | cut -d'"' -f4)"
  [ -n "$REG_TOKEN" ] || { echo "failed to mint registration token — check the PAT scope (repo admin)"; exit 1; }
else
  echo "provide GH_RUNNER_TOKEN (a registration token) or GH_PAT (to mint one)" >&2
  exit 1
fi

# ── download + unpack the runner (idempotent) ─────────────────────────────────
mkdir -p "$RUNNER_DIR"; cd "$RUNNER_DIR"
if [ ! -x ./config.sh ]; then
  TARBALL="actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz"
  echo "downloading ${TARBALL}…"
  curl -fsSL -o "$TARBALL" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${TARBALL}"
  tar xzf "$TARBALL"
fi

# ── register with the CLIENT label + install as a service ─────────────────────
# --replace makes re-runs safe (re-registers the same name instead of erroring).
./config.sh \
  --url "https://github.com/${REPO}" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "self-hosted,${CLIENT}" \
  --unattended --replace

# Run as a systemd service so it survives reboots / factory power-cycles.
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status || true

echo
echo "✅ runner '${RUNNER_NAME}' registered with labels [self-hosted, ${CLIENT}] on ${REPO}."
echo "   Verify: repo → Settings → Actions → Runners (should show it Idle/green)."
echo "   Now the 'Client Edge Deploy' action with client=${CLIENT} will land HERE."
