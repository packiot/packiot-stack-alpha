# ADR 0005 — Edge-nodered self-hosted runner deployment per factory

**Status:** Proposed
**Date:** 2026-06-29
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team

---

## Context

### What exists today

The `edge-node-red` repo **already has a per-client self-hosted runner deploy pattern**, but it's underused and not standardised:

```yaml
# edge-node-red/.github/workflows/enterprise-neopac-wil-deploy.yml
on:
  workflow_dispatch:           # ← manual trigger only
jobs:
  deploy:
    uses: ./.github/workflows/deploy-template.yml
    with:
      enterprise_label: 'neopac-wil'
    secrets:
      docker_username: ${{ secrets.DOCKER_USERNAME }}
      service_account: ${{ secrets.ENTERPRISE_NEOPAC_WIL_SERVICE_ACCOUNT }}
      id_enterprise:   ${{ secrets.ENTERPRISE_NEOPAC_WIL_ID }}
      api_key:         ${{ secrets.ENTERPRISE_NEOPAC_WIL_API_KEY }}
      ...
```

```yaml
# edge-node-red/.github/workflows/deploy-template.yml
jobs:
  deploy:
    runs-on:
      labels: [ self-hosted, "${{ inputs.enterprise_label }}" ]   # ← per-client runner
    steps:
      - actions/checkout@v4
      - docker/login-action@v3
      - run: sed -i 's/<hash>/'"$HASH"'/g' $COMPOSE_FILE
      - run: docker compose -f $COMPOSE_FILE up -d --wait
      - run: curl -X POST $HTTP_LOAD_FLOWS -d '{"action":"loadAll"}'
```

So the architecture exists: **each factory PC runs a GitHub self-hosted runner labeled with the enterprise name**; a per-enterprise workflow file routes the deploy to the right runner.

### What's missing

| Gap | Current state | Impact |
|---|---|---|
| **Trigger** | `workflow_dispatch` (manual only) | Ops engineer has to manually trigger every deploy; no continuous delivery |
| **Config consumption** | ~10 GitHub Secrets per client + a few env vars | Sprawls per the problem ADR-0004 documents; this ADR depends on ADR-0004 landing |
| **Version observability** | None | No way to know "which factories are on which edge-nodered SHA"; can't answer "did the v1.2.4 rollout reach factory X?" |
| **Rollback story** | Nothing | A bad deploy means SSH into the factory PC + manual `git checkout <prev-sha> && docker compose up -d` |
| **Canary / phased rollout** | None | All-factories-at-once is the only mode; one bad commit takes down every factory |
| **Self-hosted runner hardening** | Default GitHub registration | Runner has full access to the factory's local Docker daemon; if the runner registration token leaks, attacker can run arbitrary jobs on the factory PC |
| **Offline behaviour** | Runner just disconnects | Factory loses internet → runner offline → deploy queues at GitHub → when internet returns, deploy fires (potentially mid-shift) |

### Why now

- The staging stack is mature; the edge-nodered changes shipped this session (ErrSkipReplay handlers, classifier extensions) prove the codebase is at the "real deployment to clients" inflection point.
- ADR-0004 introduces a per-client config file; once that lands, this ADR makes the runner workflow consume it cleanly.
- The current `workflow_dispatch`-only model is operationally expensive — every staging-branch push to edge-node-red requires N manual workflow-dispatch runs across the fleet.

---

## Decision

Standardise the per-factory self-hosted runner pattern with these specific changes from the current state:

1. **Change trigger from `workflow_dispatch` to `push` on `staging` branch** (matches the parent-stack convention from `deploy-staging.yml`). Manual `workflow_dispatch` remains as an escape hatch.
2. **Replace per-client GitHub Secret sprawl** with the per-client `clients/<id>/client.yaml` from ADR-0004 + a single `CLIENT_ID` workflow input. Sensitive values (API keys, service accounts) stay in Secrets Manager — loaded by `entrypoint.sh` via `AWS_SECRET_ID` (mechanism already in place).
3. **Add a "fleet version" dashboard** — each runner reports its current SHA after a successful deploy via a thin POST to a central edge-api endpoint; Grafana panel reads from this.
4. **Add a rollback workflow** — `rollback-edge-nodered.yml` taking `client_id` + `target_sha` inputs; same deploy-template flow but pinned to an arbitrary commit instead of HEAD.
5. **Phased rollout via deploy "rings"** — runners are labeled with both `enterprise_label` and `ring` (`canary` / `production`). Canary factories deploy on every push; production factories deploy on a delayed schedule (e.g. 24h after canary passes).
6. **Offline tolerance is GitHub-Actions-native** — the runner queues the deploy when it reconnects; we don't build custom offline-deploy logic. **But:** we add a "max-deploy-age" guard in the workflow — if the queued deploy is >7 days old when it runs, skip + alert (operator-driven re-trigger).

### Architecture

```
   edge-node-red repo (GitHub)
        │
        │ push to staging branch
        ▼
   GitHub Actions:
   For each client.yaml in clients/:
     → deploy-template.yml run targeting runner [self-hosted, <client-id>, <ring>]
        │
        │ HTTPS pull
        ▼
   Factory PC (each one):
   ┌────────────────────────────────────────────────────┐
   │  GitHub Actions self-hosted runner                 │
   │  ┌────────────────────────────────────────────────┐│
   │  │ - git pull edge-node-red                       ││
   │  │ - read clients/<my-client-id>/client.yaml      ││
   │  │ - bake CLIENT_ID env into compose              ││
   │  │ - docker compose build && up -d                ││
   │  │ - report SHA → edge-api fleet-version endpoint ││
   │  └────────────────────────────────────────────────┘│
   │  ┌────────────────────────────────────────────────┐│
   │  │ edge-nodered container (THE actual edge stack) ││
   │  │  + local MQTT broker (if ADR-0001 lands)       ││
   │  │  + local TimescaleDB (if ADR-0001 lands)       ││
   │  └────────────────────────────────────────────────┘│
   └────────────────────────────────────────────────────┘
```

### Workflow shape (after this ADR)

```yaml
# .github/workflows/deploy-edge-nodered.yml (new — replaces per-enterprise-*-deploy.yml files)
name: Deploy edge-nodered (fleet)

on:
  push:
    branches: [staging]
  workflow_dispatch:
    inputs:
      client_id:
        description: "Single client to deploy (empty = all)"
        required: false
      ring:
        description: "canary | production | all"
        default: "all"

jobs:
  fan-out:
    runs-on: ubuntu-latest
    outputs:
      clients: ${{ steps.list.outputs.matrix }}
    steps:
      - uses: actions/checkout@v4
      - id: list
        run: |
          # Emit JSON matrix of (client_id, ring) tuples from clients/*/client.yaml
          ./scripts/list-clients.sh > matrix.json
          echo "matrix=$(cat matrix.json)" >> $GITHUB_OUTPUT

  deploy:
    needs: fan-out
    strategy:
      matrix: ${{ fromJson(needs.fan-out.outputs.clients) }}
      fail-fast: false      # one factory failure doesn't cancel the others
    uses: ./.github/workflows/deploy-template.yml
    with:
      client_id: ${{ matrix.client_id }}
      ring: ${{ matrix.ring }}
```

```yaml
# .github/workflows/deploy-template.yml (new shape — replaces today's secret sprawl)
on:
  workflow_call:
    inputs:
      client_id:
        required: true
        type: string
      ring:
        required: true
        type: string
jobs:
  deploy:
    runs-on:
      labels: [self-hosted, "${{ inputs.client_id }}", "${{ inputs.ring }}"]
    env:
      CLIENT_ID: ${{ inputs.client_id }}
      AWS_SECRET_ID: packiot/edge-nodered/${{ inputs.client_id }}      # one secret per client
    steps:
      - actions/checkout@v4
      - name: Sanity — client.yaml exists
        run: test -f clients/$CLIENT_ID/client.yaml || exit 1
      - name: Skip if deploy is too old (>7d queued)
        run: |
          AGE_DAYS=$(( ($(date +%s) - $(date -d "${{ github.event.head_commit.timestamp }}" +%s)) / 86400 ))
          if [ $AGE_DAYS -gt 7 ]; then
            echo "::warning::Deploy is ${AGE_DAYS}d old; skipping. Manually re-trigger via workflow_dispatch."
            exit 0
          fi
      - run: docker compose up -d --build --wait
      - name: Report SHA to fleet-version endpoint
        run: |
          curl -fsSL -X POST "$EDGE_API_BASE_URL/api/internal/fleet-version" \
            -H "x-api-key: $API_KEY" \
            -d "{\"client_id\":\"$CLIENT_ID\",\"sha\":\"${{ github.sha }}\",\"ring\":\"${{ inputs.ring }}\"}"
```

---

## Consequences

### Positive
- **Continuous delivery to factories.** Push to staging → fleet redeploys without manual intervention.
- **Fleet observability becomes real.** A Grafana panel listing "Factory X: SHA abc1234 (canary, ring=canary)" + "Factory Y: SHA def5678 (production, ring=production)" makes the fleet's state visible at a glance.
- **Canary protects production fleet.** A bad commit hits the canary ring first; if canary metrics degrade (DLQ growth, error rate, lag), an automatic alert holds the production ring at the previous SHA pending manual sign-off.
- **Rollback is one workflow_dispatch.** Operator picks `client_id` + `target_sha`, workflow fires the same deploy chain pointed at the old commit. No SSH-to-factory required.
- **Per-client config (ADR-0004) replaces secret sprawl.** Onboarding a new client = `cp -r clients/_template clients/newclient` + edit YAML + register runner. The 10+ per-client GitHub Secrets collapse to one per-client AWS Secrets Manager entry.

### Negative
- **Self-hosted runner security surface.** A runner with write access to docker on a factory PC is a high-value compromise target. Need: dedicated `runner` user, no sudo, network egress whitelisted to GitHub + Secrets Manager only, runner registration tokens rotated quarterly.
- **Concurrent fleet deploys can rate-limit GitHub.** 20 factories pulling the repo simultaneously can hit secondary rate limits. Mitigation: stagger via the ring system + `fail-fast: false`.
- **Push-on-staging changes the deploy cadence dramatically.** Today: manual workflow_dispatch (intentional, infrequent). After this ADR: every staging push deploys to every canary factory (auto). This needs explicit team sign-off — it's a culture change, not just code.
- **The "max-deploy-age=7d" skip is a partial solution.** If a factory comes back online after 8 days of disconnect, it'll skip the queued staging push — but it'll also skip the deploy it actually wanted. The operator workflow for "I just need this factory current right now" must be documented.
- **Fleet-version dashboard adds a new edge-api endpoint** (`POST /api/internal/fleet-version`) — small but real surface area. Needs auth + idempotency.

### Mitigations
- **Hardening checklist for new factory runner installs**: dedicated user, network egress allowlist, audit log, monthly registration-token rotation. Codify in `docs/runbook/runner-install.md`.
- **Ring system absorbs rate-limit risk.** Canary = 1-2 factories deployed first; production = N factories on delayed schedule. GitHub rate limits are per-org, not per-runner.
- **Document the "I'm OK with auto-deploy" team decision** in CONTRIBUTING.md. Explicitly state: pushing to edge-node-red/staging deploys to every canary factory within minutes. No surprises.
- **Stale-queue skip alerts** — when the 7-day skip fires, post to a `#fleet-alerts` channel so ops knows a manual re-trigger is needed.

---

## Alternatives considered

### A. Status quo (workflow_dispatch + per-enterprise YAML per client)
- ✅ Zero change
- ❌ All the pain points listed in "What's missing" persist
- ❌ Onboarding cost compounds linearly with client count
- **Why not chosen:** Doesn't solve the problem the user explicitly named.

### B. Schedule-based pull (factory PC polls every N minutes for a new SHA)
- ✅ No GitHub push-trigger complexity; factory drives its own update cadence
- ❌ Adds a polling cron (more moving parts on the factory PC)
- ❌ No "this commit just landed; deploy now" responsiveness
- **Why not chosen:** Push-driven matches the parent-stack staging pattern; team is already familiar with it.

### C. Ansible / similar config-mgmt over SSH (no GitHub runner on factory)
- ✅ Familiar tooling for many ops teams
- ❌ Requires opening SSH inbound from a control plane to every factory (vs the current "factory pulls from GitHub" outbound-only model)
- ❌ Loses GitHub Actions' workflow YAML + observability + audit log
- **Why not chosen:** Outbound HTTPS to GitHub is a strictly smaller security surface than inbound SSH from cloud.

### D. Per-factory branch (`client/cpack-line5`, `client/cpack-line6`, etc.)
- ✅ Each physical factory pins its own version explicitly
- ❌ Branch sprawl (covered in ADR-0004 alternatives)
- ❌ Doesn't actually solve the "trigger" question — still need a workflow + runner
- **Why not chosen:** ADR-0004 already rules this out; same logic applies here.

---

## Implementation phases

| Phase | Scope | Effort | Risk |
|---|---|---|---|
| **0 — Design + ADR** | This document | done | N/A |
| **1 — ADR-0004 must land first** | Per-client YAML config + schema validator | depends on ADR-0004 | depends |
| **2 — New `deploy-edge-nodered.yml` workflow + fan-out matrix** | Replaces all `enterprise-*-deploy.yml` files. Trigger stays `workflow_dispatch` only for the first week (validate fan-out logic without auto-firing). | 1 week | Low (no auto-trigger yet) |
| **3 — Fleet-version reporting + Grafana panel** | New `edge-api /api/internal/fleet-version` endpoint + DB table + Grafana panel. Runners start reporting. | 1-2 weeks | Low |
| **4 — Canary ring + auto-trigger on canary** | Add `ring` label to canary factory. Enable `push: [staging]` trigger but only for canary ring. Observe for 2 weeks. | 2-3 weeks | Medium (real auto-deploy traffic, but only to canary) |
| **5 — Production ring auto-deploy + rollback workflow** | Enable auto-trigger for production ring with 24h delay after canary lands. Ship rollback workflow. | 2-3 weeks | Medium-High (full-fleet auto-deploy) |
| **6 — Hardening + runbook** | Runner user, egress allowlist, registration rotation runbook, fleet-state dashboard polishes | ongoing | Low |

---

## Open questions

1. **Runner installation method.** Manual `./config.sh && ./run.sh` per factory, or templated via cloud-init / Ansible / Salt? Affects onboarding ergonomics.
2. **Runner authentication rotation.** GitHub registration tokens expire after 1 hour for new registrations; long-lived runners use a different token. Need explicit rotation policy.
3. **Canary selection.** Which factory is "the canary"? Pick a low-stakes site? Internal demo factory? Customer with the highest tolerance for issues?
4. **24h-canary-soak duration.** Is 24h enough? Some bugs (refresh-flow auth from ADR-0002) take a full operator shift to surface. Maybe 48h or 1 full production-week.
5. **What metrics gate canary → production promotion?** DLQ depth, error rate, container restart count, edge-nodered uptime, ... — needs concrete thresholds.
6. **Rollback policy.** Automatic on canary-fail, or always manual? Auto-rollback has its own risks (oscillation, can revert the fix for an unrelated issue).
7. **Internet outage > 7d skip alert routing.** Where does the alert go? Slack? Email? PagerDuty?
8. **Network requirements for runners.** Whitelist *.github.com, *.githubusercontent.com, *.docker.io, *.amazonaws.com? Document in onboarding runbook.
9. **Fleet-version endpoint authentication.** Per-client API key (each runner has its own)? Or org-wide shared key? Auth model affects what the endpoint trusts.
10. **Concurrent same-factory deploys.** What if a manual workflow_dispatch fires while an auto-staging-push deploy is mid-flight? Reuse the same `concurrency:` group pattern from `deploy-staging.yml`.

---

## References

- [`edge-node-red/.github/workflows/deploy-template.yml`](../../edge-node-red/.github/workflows/deploy-template.yml) — existing template; this ADR's new shape replaces it
- [`edge-node-red/.github/workflows/enterprise-neopac-wil-deploy.yml`](../../edge-node-red/.github/workflows/enterprise-neopac-wil-deploy.yml) — existing per-enterprise workflow; phase 2 replaces all of these
- [`edge-node-red/entrypoint.sh`](../../edge-node-red/entrypoint.sh) — `AWS_SECRET_ID` loader that this ADR keeps as the secrets pathway
- [`.github/workflows/deploy-staging.yml`](../../.github/workflows/deploy-staging.yml) — parent stack's staging deploy; the model for trigger / concurrency / runner-label conventions adopted here
- [[ADR 0001]] — edge persistence; affects what runs alongside edge-nodered on the factory PC long-term
- [[ADR 0003]] — production deployment; this ADR is the edge-side companion
- [[ADR 0004]] — config centralization; **hard prerequisite** for this ADR's CLIENT_ID-driven workflow
- [GitHub Actions self-hosted runners docs](https://docs.github.com/en/actions/hosting-your-own-runners) — official reference for the runner model
