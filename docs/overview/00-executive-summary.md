# Packiot Platform Modernization — Executive Summary

> Audience: management, stakeholders, anyone who needs the "what and
> why" in ten minutes. Engineers: continue to
> [01-architecture](01-architecture.md) and
> [05-onboarding](05-onboarding.md).
>
> Scope: the full modernization program, from the first staging
> environment ("Flow 1") through today. Status date: 2026-07-06.

## The initiative

The Packiot OEE platform's core runs on legacy technology: ~150
unversioned database stored procedures computing all business math,
Node-RED visual-programming flows handling ingestion and automation,
and a GraphQL layer (Hasura) that a usage audit showed **4% utilized**.
It works — customers depend on it daily — but it is untestable,
unobservable, and increasingly expensive to change safely.

The program rebuilds this core as a modern, tested, observable **Go
service stack**, under one non-negotiable rule: **100% behavioral
parity at every customer-facing surface** (PowerBI reports, dashboards,
customer data syncs) before any production cutover. All work has run
on purpose-built staging infrastructure at **~$35/month total AWS
cost — zero additional spend** beyond the two EC2 instances.

## What has been built, phase by phase

### 1. A production-grade staging platform (from nothing)

Two EC2 instances now run the entire platform: ~15 services under
Docker Compose, deployed automatically on every merge (GitHub Actions
→ self-hosted runner), with full observability (Grafana, Prometheus,
Loki), daily EBS backups, disk-pressure guards, and a rehearsal
production environment. Infrastructure is code (Terraform); deploys
are one merge; rollbacks are one revert.

### 2. Live production data, safely mirrored

A Go **mirror-worker** streams real production activity (production
orders, machine events, production counts) into staging under a hard
rule that has never been broken: **production is read-only, always.**
A companion **shadow-mirror** replays real operator actions
(downtime justifications, order starts/stops) so staging behaves like
a real factory, not a synthetic demo. An **operator web app** on
staging exercises the same workflows customers use.

### 3. Ingestion modernized to the industrial-IoT standard

A new Go **edge-transformer** replaces the Node-RED ingestion layer:
native **MQTT / Sparkplug B** (the industry standard protocol) with
durability guarantees the legacy system never had — broker
persistence, publisher confirmations, store-and-forward buffering,
health endpoints with named degradation reasons. The Sparkplug
decoder was cross-verified against the exact library the legacy
system uses; throughput headroom measured at ~13,000× current load.
The legacy cloud Node-RED instance (oeecloud-node-red) has already
been **decommissioned**; a Go simulator now stands in for factory
PLCs on staging, feeding every environment identically —
verified row-for-row.

### 4. The compute engine, rewritten and mathematically proven

Every live legacy function in the OEE pipeline now runs as Go code:
production-order lifecycle, the hourly / daily / weekly / monthly /
shift roll-up cascade for machines, areas and sites, live "current
state" dashboards, and per-customer report writers. A purpose-built
differential harness compared old vs. new on identical real data:

| Subject | Rows compared | Mismatches |
|---|---:|---:|
| PO recalc pass | 13,162 | **0** |
| PO compute pass | 13,432 | **0** |
| Hourly roll-up | 198 | **0** |
| Daily roll-up | 1,716 | **0** |
| Shift roll-up | 4,340 | **0** |
| **Total** | **32,848** | **0** |

The first legacy database trigger has already been formally retired,
on evidence stronger than the planned test window required.

### 5. The data model, untangled for multi-tenancy

Per-customer copy-paste tables (one hardcoded table per client per
report) are replaced by shared, tenant-keyed pools with
**configuration instead of code** for customer-specific behavior —
onboarding a new customer's report becomes one database row instead
of a development project. Legacy names live on as compatibility
views so nothing downstream breaks. A new **query-api** provides the
modern read side.

### 6. Verification as a permanent capability, not a project phase

A comparator service runs 24/7 diffing the legacy and new engines on
the same live stream (Grafana board with a stated reading discipline:
every non-zero number must carry a named cause and an expiry date).
Golden-fixture tests in CI freeze proven behavior against regression.
This machinery repeatedly caught latent defects before they could
reach production — including a data-corruption feedback loop that
had silently fabricated ~1.5 billion units of phantom production on
staging, several misleading "dead" legacy code paths, and a missing
data connection that had left part of the new engine idle. Every
incident produced a permanent structural safeguard.

### 7. The cutover, de-risked to a checklist

Historical data is preserved. A written **~30-minute cutover
runbook** exists, fully reversible with a 30-day safety window, plus
a 9-item decommissioning list retiring the legacy Node-RED services,
the Hasura layer (direct savings: $600–2,400/year plus operational
complexity), and all shadow infrastructure.

## What remains

- **~1 week** of automated comparison evidence (already accumulating
  unattended; window ends ~2026-07-13).
- **Three business sign-offs**: PowerBI report owners (37-object
  compatibility gate), one cross-team API coordination for a customer
  data sync, one dashboard-retirement confirmation.
- Then: execute the staging cutover, observe the 30-day window, and
  plan the production migration with everything staging-proven.

## Bottom line

In roughly six weeks, on ~$35/month of infrastructure, the platform's
core has been rebuilt, proven identical to the legacy system across
32,848 measured outputs, hardened with durability and monitoring the
legacy never had, and staged for a 30-minute reversible cutover.
**The engineering risk has been retired up front; what remains is
calendar time and approvals — not invention.**
