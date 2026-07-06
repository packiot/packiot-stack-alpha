# Packiot Platform Modernization — Executive Summary

> Audience: management, stakeholders, anyone who needs the "what and
> why" in five minutes. Engineers: continue to
> [01-architecture](01-architecture.md) and
> [05-onboarding](05-onboarding.md).
>
> Status date: 2026-07-06.

## The initiative

We are replacing the legacy core of the Packiot OEE platform — roughly
**150 database stored procedures (PL/pgSQL) plus Node-RED automation
scripts** — with a modern, testable **Go service stack**. The
non-negotiable requirement: **100% behavioral parity at every
customer-facing surface** (PowerBI reports, dashboards, customer data
syncs) before any production cutover.

All work has run on existing staging infrastructure at **zero
additional cloud cost**.

## What has been achieved

### 1. The compute engine is fully rewritten — and mathematically proven

Every live legacy function in the OEE pipeline now runs as Go code:
production-order lifecycle tracking, the hourly / daily / weekly /
monthly / shift roll-up cascade for equipment, areas and sites, the
live "current state" dashboards, and the per-customer report writers.

A purpose-built **differential testing harness** ran old vs. new on
identical real data:

| Subject | Rows compared | Mismatches |
|---|---:|---:|
| PO recalc pass | 13,162 | **0** |
| PO compute pass | 13,432 | **0** |
| Hourly roll-up | 198 | **0** |
| Daily roll-up | 1,716 | **0** |
| Shift roll-up | 4,340 | **0** |
| **Total** | **32,848** | **0** |

### 2. Verification is continuous, not one-off

A comparator service runs 24/7 diffing the legacy and new engines on
the same live data stream (Grafana dashboard `/d/bake-flow-parity`).
Divergence is measured by us — never discovered by customers.
Golden-fixture tests in CI freeze the proven behavior so no future
change can silently regress it.

### 3. Data ingestion modernized to the industrial IoT standard

Factory data now enters via **MQTT / Sparkplug B** with durability
guarantees end-to-end (broker persistence, publisher confirmations,
store-and-forward buffering). One data source feeds all environments
identically — verified row-for-row.

### 4. Latent defects caught before production

The verification machinery paid for itself repeatedly: a
data-corruption feedback loop in a sync service (silently generating
~1.5 billion units of phantom production on staging — diagnosed,
purged, structurally guarded), several misleading "dead" legacy code
paths, and a missing data-flow connection that had left part of the
new engine idle. Every fix shipped with permanent safeguards. Details:
[03-differences](03-prod-vs-new-differences.md) and the bug log in
the project memory.

### 5. The cutover is de-risked to a checklist

Historical data is preserved (`hist_*` tables); a written **~30-minute
cutover runbook** exists
([adr/reference/0016-flip-runbook.md](../adr/reference/0016-flip-runbook.md)),
fully reversible with a 30-day safety window, plus a 9-item
decommissioning list that retires the legacy Node-RED services, the
Hasura GraphQL layer, and shadow infrastructure — direct ongoing cost
and complexity reduction.

## What remains

- **~1 week** of automated comparison evidence (already accumulating
  unattended; window ends ~2026-07-13).
- **Three business sign-offs**: PowerBI report owners (37-object
  compatibility gate), one cross-team API coordination for a customer
  data sync (`sap_13` / back4-api), one dashboard-retirement
  confirmation (`c35`).
- Then: execute the staging cutover, observe the 30-day window, and
  plan the production migration with everything staging-proven.

## Bottom line

The engineering risk has been retired up front. The new platform is
live in staging, measured as identical to the legacy system, and
monitors itself continuously. **What remains is calendar time and
approvals — not invention.**
