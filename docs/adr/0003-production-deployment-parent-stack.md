# ADR 0003 — Production deployment of the parent stack

**Status:** Proposed
**Date:** 2026-06-29
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team

---

## Context

### Where we are today

Two compute environments exist:

| Environment | Stack | Database |
|---|---|---|
| **Staging** (new) | `compose.staging.yml` on Terraform-provisioned EC2s (app + db), full auto-deploy chain via `deploy-staging.yml` | Self-hosted TimescaleDB on a dedicated EC2 |
| **Production** (legacy) | edge-api on Elastic Beanstalk (`edge-api-prod-docker-env` → `edge.api4.packiot.com`) | Existing prod TimescaleDB |

The new stack — pgbouncer, hasura, edge-api, edge-nodered, mirror-worker-go, oeecloud-worker, operator SPA, observability triad (Grafana + Loki + Prometheus + promtail), Authentik SSO gate — runs only on staging today. The legacy prod is a single edge-api Docker app on EB; the rest of the new stack has no prod counterpart.

### What we want

A new production environment that mirrors the staging architecture, so the same code paths + observability + deploy chain work in prod. **Crucially: no changes to the existing prod database** — the new prod stack connects to today's prod TimescaleDB as a *consumer*, not a replacement. Phased migration to writes later, in a separate ADR.

### Why now

- All recent ADR-relevant work (mirror-worker correctness, OEE pipeline parity, edge-nodered behaviour) has been validated against staging only. The leap from staging → real customer traffic remains untested.
- Multiple recent fixes (PRs #82, #83, #84, #87, #88) prove the staging stack is mature enough to deploy elsewhere with confidence.
- Customer-facing prod migration off Elastic Beanstalk is overdue; this ADR is the first prerequisite step.

---

## Decision

Provision a new prod environment **structurally identical to staging**, isolated under a separate Terraform workspace, separate Secrets Manager namespace, separate domain. **It connects to the existing prod TimescaleDB read-only initially** — no prod DB schema changes, no writes from new prod services. The new prod is a shadow / read replica of customer data while we validate that the staging-quality code behaves correctly under real prod load.

### Architectural shape

```
                                ┌─ new prod EC2 (app) ─────────────────┐
                                │  ┌────────────────────────────────┐  │
                                │  │  pgbouncer · hasura · edge-api │  │
                                │  │  edge-nodered (test client?) · │  │
                                │  │  mirror-worker-go ·            │  │
                                │  │  oeecloud-worker · operator    │  │
                                │  │  grafana · loki · prom · etc.  │  │
                                │  └────────────┬───────────────────┘  │
                                │               │ SELECT-only          │
                                │               ▼                      │
                                │   existing prod TimescaleDB ─────────┼──┐
                                │   (NO TF-managed changes, NO         │  │
                                │    schema migrations, NO writes      │  │
                                │    until phase 3 of this rollout)    │  │
                                └──────────────────────────────────────┘  │
                                                                          │
                          ┌── existing prod TimescaleDB ─────────────────┘
                          │ (lives outside this ADR's blast radius)
                          └──── current prod edge-api on EB (decommission later)
```

### What's the same as staging
- Compose file shape: `compose.production.yml` mirrors `compose.staging.yml` field-for-field
- Container set: same 17 services
- Observability: Grafana + Loki + Prometheus + promtail same versions
- Auto-deploy chain: push to a prod branch → self-hosted runner on prod EC2 → `docker compose build && up -d`
- Secret loading model: `AWS_SECRET_ID` env var → entrypoint pulls JSON → exports as env

### What's different from staging
- **Separate Terraform workspace** — `terraform/production/` is a near-copy of `terraform/staging/` with these deltas:
  - VPC CIDR doesn't overlap staging (e.g. `10.20.0.0/16`)
  - Instance sizes likely bigger (`t4g.large` minimum, probably `t4g.xlarge` for app since prod customer load + observability stack + edge-nodered)
  - EBS sizes bigger (256 GB app, 512 GB db-EC2-stub-volume — though no db actually runs there since we use existing prod DB)
  - Domain: `prod.packiot.app` (or whichever the team picks)
  - Backup retention: 30 days instead of staging's 7
- **Separate Secrets Manager namespace** — `packiot/production/*` (db creds, hasura admin secret, nginx-auth, github-runner, ec2-rescue, etc.)
- **Auto-deploy trigger** — `push` on a `production` branch (matches the staging convention of `staging` branch). Promotion from staging to prod = merge `staging` → `production` (separate PR, separate review).
- **No local TimescaleDB EC2** — there is no `terraform/production/ec2.tf::aws_instance.db` resource at all in phase 1. Compose stack's pgbouncer + hasura point at the existing prod DB endpoint via Secrets Manager-supplied credentials.
- **Authentik SSO** — the outer gate stays, but provisioning is separate (own database, own admin password, own bootstrap secret).
- **Mirror-worker source name** — `cpack-prod-go-PROD` (or similar) so its cursor + mirror_id_map don't collide with staging's `cpack-prod-go`.

### What is explicitly NOT in this ADR
- Migrating writes from old prod (EB-based edge-api) to new prod
- Decommissioning the EB environment
- Customer DNS cutover (`edge.api4.packiot.com` stays pointed at EB during phase 1)
- Schema changes to the prod database (forbidden by the existing [prod DB SELECT-only rule](feedback_prod_db_readonly.md))
- Edge-nodered per-factory deploys (separate ADR-0005)
- Per-client config standardization (separate ADR-0004)

---

## Consequences

### Positive
- **All new-stack code paths run against real prod data.** Mirror-worker, observability, OEE caggs, operator UI — all exercised on prod-scale load before we cut writes.
- **Two-way verification.** Discrepancies between the new prod stack's read-only computation and the old prod's authoritative state become a useful canary for "is the new stack actually faithful?"
- **Reversible.** New prod compute runs in parallel with old EB; nothing changes for customers until we explicitly cut traffic.
- **Same operational primitives as staging.** Disk-fill alarms, AWS Backup snapshots, docker-prune timer, Serial Console rescue — all already designed; just apply to prod EC2s.

### Negative
- **2× AWS spend on compute + storage.** New prod EC2s + EBS + NAT + Route53 + Secrets Manager add ~$150-300/mo (rough; needs sizing).
- **Operational surface doubles.** Two compose stacks to monitor; deploys fan out; oncall rotation needs to cover both.
- **Edge-nodered's role in new prod is undefined.** Phase 1 likely runs without a real per-customer edge-nodered (the per-factory deploys are ADR-0005's scope) — so the "prod edge-nodered" in compose.production.yml is either omitted or runs a test-only flow set.
- **Phase 3 (cutting writes) is the actually-risky part** and is deferred — this ADR doesn't unblock customer migration on its own.

### Mitigations
- **Phase the spend.** Phase 1 uses staging-equivalent instance sizes; bump only if observed load demands it.
- **Reuse staging's operational tooling 1:1.** Disk alarms, Backup plans, Serial Console rescue copy over with a search-and-replace from `staging` to `production`.
- **Defer the edge-nodered question.** Phase 1's `compose.production.yml` either omits `edge-nodered` entirely or runs it pointed at a test enterprise — the real story lives in ADR-0005.

---

## Alternatives considered

### A. Skip new-prod compute entirely; just point new code at prod DB from staging
- ✅ Zero new infra
- ❌ Staging is for QA, not load; running customer-facing code from staging compute breaks the staging-vs-prod separation we've been building all month
- ❌ No fresh Authentik / nginx / monitoring instance dedicated to prod

### B. New prod with new DB (full Terraform parity)
- ✅ True Infrastructure-as-Code parity
- ❌ Requires data migration from existing prod DB → new prod DB (logical replication, downtime windows, customer comms)
- ❌ Multi-week effort; not the right scope for "let's stand up a prod stack"

### C. Promote staging to prod (rename)
- ✅ Zero new infra
- ❌ Staging is needed for QA going forward; renaming it removes our test environment
- ❌ No phased migration story; flip-the-switch deploys are exactly the anti-pattern this whole month has been moving away from

---

## Implementation phases

| Phase | Scope | Effort | Risk |
|---|---|---|---|
| **0 — Design + ADR** | This document | done | N/A |
| **1 — Stand up new prod (read-only)** | Copy `terraform/staging/` → `terraform/production/` with the deltas above. New `compose.production.yml`. New `packiot/production/*` secrets. New `deploy-production.yml` workflow. New runner. New domain. Compose stack runs against existing prod DB read-only. | 1-2 weeks | Low (parallel to existing prod; no customer impact) |
| **2 — Observability + load validation** | Run new prod in parallel for ~2 weeks. Compare metrics: are the OEE numbers staging-vs-prod-stack consistent? Are query patterns sane? Are alerts noisy or useful? | 2-3 weeks | Low (observation only) |
| **3 — Cut prod writes** | Separate ADR. Includes migration of EB-based edge-api's customer-facing API → new prod edge-api. Customer DNS cutover. Old EB decommission. | 4-8 weeks | **High** (customer-facing; requires its own design + comms) |

---

## Open questions

These need answers before Phase 1 implementation:

1. **Domain.** `prod.packiot.app`? `app.packiot.com`? Customer-facing branding matters here.
2. **Branch name.** `production`? `main`? `prod`? Today there's `staging`; for symmetry `production` is natural.
3. **Authentik provisioning.** Same admin team controls both? Separate identity provider? Mostly an ops question.
4. **edge-nodered in compose.production.yml.** Omit entirely in phase 1, or run pointed at a test enterprise, or run a dedicated `prod-internal` instance? Influenced by ADR-0005.
5. **Cost ceiling.** What's the budget envelope for phase 1 compute + storage? Drives instance sizing decisions.
6. **Mirror-worker source name.** `cpack-prod-go-prodenv`? `cpack-prod-go-PROD`? Naming convention TBD.
7. **Backup retention.** Staging is 7 days; should prod be 30, 60, 90? Affects backup-storage cost line.
8. **Reverse-DNS / TLS.** Authentik + nginx + ACM cert for the new domain — same shape as staging's `nginx_setup.sh` but with new ACM ARNs.

---

## References

- [Staging Terraform — `terraform/staging/`](../../terraform/staging/) — the template this prod env mirrors
- [`compose.staging.yml`](../../compose.staging.yml) — the compose template
- [`deploy-staging.yml`](../../.github/workflows/deploy-staging.yml) — the deploy workflow template
- [Prod DB SELECT-only rule](../../.claude/projects/-home-podesta-github-packiot-packiot-stack-alpha/memory/feedback_prod_db_readonly.md) — the constraint this ADR honors throughout phase 1 + 2
- [[ADR 0001]] — edge persistence (informs how prod-side observability fits)
- [[ADR 0004]] — edge-nodered config centralization (companion ADR)
- [[ADR 0005]] — edge-nodered self-hosted runner deploys (companion ADR)
