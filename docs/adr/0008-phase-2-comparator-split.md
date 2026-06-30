# ADR 0008 — Phase 2 split: comparator service + deferred data layer

**Status:** Proposed (amends ADR-0003 phase 2)
**Date:** 2026-06-30
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team

---

## Context

ADR-0003 proposed standing up a new production environment that mirrors staging architecturally and connects **read-only** to the existing prod TimescaleDB (`tsp12`). Phase 1 (dry-run boot of the new stack with a local-only postgres) shipped session 71. Phase 2 was stated as:

> *"Run new prod in parallel for ~2 weeks. Compare metrics: are the OEE numbers staging-vs-prod-stack consistent? Are query patterns sane? Are alerts noisy or useful?"*

Two constraints collide with that framing:

### Constraint 1 — `tsp12` is SELECT-only by discipline

The `awslambda` role on `tsp12` has `rolcreatedb=f`, `rolsuper=f`, and no LOCK TABLE / REPLICATION privileges. This is documented in [`prod-db-select-only`](../../.claude/projects/-home-podesta-github-packiot-packiot-stack-alpha/memory/feedback_prod_db_readonly.md) as a hard rule: **only SELECTs ever run against production**. The constraint is self-imposed (the project owner is the de-facto DBA), not externally enforced, but treating it as if it were external is a deliberate discipline — preserves the option to involve external DBAs later, prevents accidental privilege creep, and forces every prod-data access pattern to be auditable as a read.

### Constraint 2 — every service in the new prod stack needs write capability

| Service | Write requirements |
|---|---|
| `hasura` | `hdb_catalog` schema (metadata, migrations, state) |
| `authentik-server` / `worker` | own DB (users, sessions, tokens, policies) |
| `edge-api` | `user_logs`, `production_orders`, `downtimes`, `equipment_events`, `samples`, etc. on every customer-facing API call |
| `mirror-worker-go` | `mirror_replay_dlq`, `mirror_id_map`, `mirror_replay_cursor` |
| `oeecloud-worker` | `equipment_values`, `equipment_events`, `uns_metrics` |
| Operator SPA | hits `edge-api` → cascades to all of the above |

**No service can use `tsp12` as its primary datastore** under the SELECT-only constraint. ADR-0003's phase 2 wording presumed otherwise.

### The unconflated questions

Phase 2 as written actually conflates two distinct validation goals:

1. **"Is the mirror-worker faithful to prod?"** — answerable by SELECT-only comparison of prod ground-truth vs the staging mirror's reconstruction. No new stack required.
2. **"Does the new prod stack behave correctly under prod-scale load?"** — requires the stack to actually serve real-data queries + emit alerts under representative traffic. Requires real data in its local store. This is the genuinely hard problem.

These conflate because both are framed as "parallel observation," but they need different infrastructure.

---

## Decision

Split phase 2 of ADR-0003 into two sub-phases:

### Phase 2a — Comparator service (this ADR's scope)

A new periodic goroutine inside `mirror-worker-go` that:
- SELECTs canonical ground-truth values from `tsp12` (read-only, `awslambda` creds)
- SELECTs the same logical values from the staging mirror DB
- Computes divergence
- Emits Prometheus metrics with `{metric, severity}` labels
- Logs WARN/ERROR on divergence beyond configured thresholds

**Goal:** answer "is the mirror faithful?" within days. Establishes a permanent, auditable fidelity signal that becomes load-bearing for any future migration decision.

**Implementation site:** new `internal/comparator/` package in `services/mirror-worker-go/`. Reuses existing prodDB + stagingDB pool wiring. Wired alongside the existing reconcilers + DLQ retry in `main.go`. No new service binary, no new container, no new EC2 — just an additional goroutine in the existing worker process.

**Cadence:** 5 minutes (matches `RECONCILE_INTERVAL_SEC` default — pairs naturally with the existence reconciler's cycle).

### Phase 2b — Data layer for the new prod stack (deferred to ADR-0009)

Once 2a confirms mirror fidelity (or surfaces divergence requiring a fix), decide between:
- **Logical replication** from `tsp12` to a new prod-local TimescaleDB (would require granting `REPLICATION` role on `tsp12` — relaxes the SELECT-only discipline)
- **Custom schema introspection** via `pg_catalog` + `pg_get_*` functions (no privilege escalation; produces real DDL; data sync via SELECT-only ETL)
- **Periodic ETL snapshots** to the new prod-local DB (real data, not real-time, low complexity)
- **Accept the gap** — new prod stack runs without real prod data; serves only as an ops/observability validation environment until phase 3 forces the cutover

Decision deferred until business pressure or comparator findings make one option clearly correct.

---

## Initial comparator metrics (5 candidates)

These are the minimum viable signal set for phase 2a. All metrics are Prometheus gauges; rate-of-change is the alerting signal, not the absolute value.

| Metric | Computation | Healthy value | Why it matters |
|---|---|---|---|
| `comparator_active_pos_diff` | `prod count(active POs) - staging count(active POs)`, scoped to enterprise=3 (CPACK) | 0 | EnsureActivePOs reconciler correctness. Non-zero means the existence pass is misclassifying or behind. |
| `comparator_events_lag_seconds` | `prod max(ts_event) - staging max(ts_event)` for CPACK equipment | < 120s | Events-sync reconciler freshness. >300s means cursor stuck or reconciler disabled. |
| `comparator_oee_divergence_pct{id_production_order}` | `abs(prod.net_production - staging.net_production) / NULLIF(prod.net_production, 0)` per active PO | < 1% | Core "is the OEE math consistent?" signal. Material divergence means value-sync drift OR pg_cron divergence between environments. |
| `comparator_dlq_anomaly_total` | count of staging `mirror_replay_dlq` entries whose `source_log_id` does not exist in `prod.user_logs` | 0 | Detects spurious DLQ entries. Non-zero means mirror is failing on user_logs rows that prod has since deleted, or there's a race in the cursor advance. |
| `comparator_user_logs_lag` | `prod max(user_logs.id) - staging.mirror_replay_cursor.last_log_id` for `source='cpack-prod-go'` | < 1000 IDs / < 60s wall-clock | Audit-log replay freshness. Large lag means main poll loop is behind. |

Three of these (active_pos_diff, events_lag, user_logs_lag) are computable in single round-trips. The OEE divergence requires a join across active POs and is the heavier query — runs less frequently (every 30 min) with a smaller batch.

---

## Consequences

### Positive
- **Answers the most important phase-2 question in days.** "Is the mirror faithful?" becomes an alerting signal, not a periodic manual investigation.
- **Reuses the existing mirror-worker process + connection pools.** No new EC2, no new secret, no new dashboard infrastructure — just additional Grafana panels + Prom metrics.
- **Honours the SELECT-only discipline.** Comparator only reads. Zero blast radius on prod.
- **Permanent fidelity signal.** Even after the new prod stack stands up against real data, the comparator continues to provide a watchdog for divergence between the two reconstructions.
- **Defers the genuinely hard architecture question** to when business pressure forces it, rather than designing speculatively.

### Negative
- **Doesn't address the "stack under load" goal.** The new prod stack continues to run with local-only data; its query patterns, alerts, and operational behavior remain unvalidated against real prod traffic. ADR-0003 phase 2 as originally scoped is not fully delivered until ADR-0009 lands.
- **Phase 3 (cut prod writes) is now further away.** Each deferred decision adds calendar time before the EB-based prod can be decommissioned.

### Mitigations
- **Ship 2a fast** so the deferral is bounded. Target: comparator service shipped within 1 week of this ADR landing.
- **Use 2a's findings to inform 2b.** If the comparator surfaces non-trivial divergence, that's a fix-first signal — the data-layer decision can wait. If divergence is minimal, the cost of postponing the data layer is lower than the cost of getting it wrong.

---

## Alternatives considered

### A. Implement ADR-0003 phase 2 as-written (full stack against tsp12 read-only)
- ❌ Requires every service to have a working write path that isn't tsp12 — at minimum a hybrid `READ_DB_URL` / `WRITE_DB_URL` model
- ❌ Significant code refactor across edge-api, hasura, mirror-worker, oeecloud-worker
- ❌ Consistency hazards (write to local DB → read from prod doesn't see it)
- ❌ Operational complexity scales with service count
- The split avoids all of this without losing the comparator value

### B. Logical replication tsp12 → new prod local (jump directly to data layer)
- ✅ Real data in new prod stack; satisfies full phase-2 vision
- ❌ Requires granting `REPLICATION` role on tsp12 — relaxes the SELECT-only discipline
- ❌ Replication slot creates WAL retention pressure on tsp12 — operational concern if slot lags
- ❌ Skips the cheaper validation that comparator would provide first
- Better to validate mirror fidelity (cheap) before committing to replication infrastructure (expensive)

### C. Comparator as a separate service / new binary
- ✅ Cleaner separation of concerns
- ❌ New service = new deploy pipeline + new container + new metrics endpoint + new dashboard mention
- ❌ Reads from the same two DBs the mirror-worker already reads from
- The marginal cost of a new service exceeds the marginal cost of a new package inside an existing service

### D. Comparator as scheduled SQL (pg_cron on tsp12 or staging)
- ✅ Zero new code
- ❌ pg_cron on tsp12 is forbidden by SELECT-only (creating a cron job is DDL)
- ❌ pg_cron on staging can't query tsp12 (no DB-link extension; no `awslambda` creds inside postgres)
- ❌ Diverges from the Prometheus-emitting pattern the rest of the stack uses

### E. Defer phase 2 entirely; do nothing until phase 3 pressure
- ❌ Loses the cheap, immediate validation value of 2a
- ❌ Mirror correctness remains a manually-investigated question; bugs only surface when operator complaints arrive

---

## Implementation phases

| Phase | Scope | Effort | Risk |
|---|---|---|---|
| **2a.0 — ADR** | This document | done | N/A |
| **2a.1 — Comparator skeleton** | `internal/comparator/` package + `RunForever` loop + main.go wiring + one trivial metric (`comparator_active_pos_diff`) end-to-end | 1 day | Low |
| **2a.2 — Metrics 2-3** | `comparator_events_lag_seconds`, `comparator_user_logs_lag` | 0.5 day | Low |
| **2a.3 — Heavier metric** | `comparator_oee_divergence_pct` (per-PO join, 30-min cadence) | 0.5 day | Medium (query cost on tsp12 — measure first) |
| **2a.4 — Anomaly metric** | `comparator_dlq_anomaly_total` (requires fetching staging DLQ source_log_ids + checking prod existence) | 0.5 day | Low |
| **2a.5 — Grafana + alerts** | New panel cluster on `mirror-worker` dashboard; alert rules for each metric | 1 day | Low |
| **2b — Data layer for new prod** | Separate ADR-0009 | TBD | TBD |

---

## Open questions

These need answers as 2a is implemented:

1. **Threshold tuning.** What's the alert threshold for `oee_divergence_pct`? 1% might be too tight for low-volume POs (where small absolute differences ≈ large percentages); 5% might be too loose for high-volume ones. Likely needs a per-PO scale factor.
2. **Query budget on tsp12.** The OEE divergence query joins production_orders + production_orders_runtime + (potentially) shifts. Need to measure cost on tsp12 before running every 30 min — cap at small batch sizes if expensive.
3. **Source name in metrics.** If a future tenant gets the same mirror treatment, comparator metrics need a `{tenant}` label. Today CPACK is the only source; default the label to `cpack`.
4. **Histogram vs gauge for lag.** `comparator_events_lag_seconds` is a single value per tick — gauge is correct. But if multiple equipments diverge differently, a histogram per-equipment might be useful. Defer to 2a.3.
5. **Should the comparator block worker startup?** No — failure to compare shouldn't take down the mirror. Use `errgroup` like the other reconcilers, with the comparator's death tolerated.

---

## Open questions deferred to ADR-0009 (phase 2b)

1. **Does the new prod stack's local DB get bootstrapped via logical replication, schema-introspection-then-ETL, or accept the gap?**
2. **Does the SELECT-only rule on tsp12 get a documented exemption for REPLICATION, or stay sacrosanct?**
3. **Cost of running new prod with no real data** — is the operational validation alone (alerts, backups, observability tooling) worth the ~$40/mo footprint?
4. **Phase 3 (cut prod writes) trigger** — what business condition forces the migration? Customer growth? EB cost? EB end-of-support?

---

## References

- [ADR-0003](./0003-production-deployment-parent-stack.md) — the parent ADR being amended
- [`feedback_prod_db_readonly.md`](../../.claude/projects/-home-podesta-github-packiot-packiot-stack-alpha/memory/feedback_prod_db_readonly.md) — the SELECT-only rule
- [`project_tsp12_pgdump_blocked.md`](../../.claude/projects/-home-podesta-github-packiot-packiot-stack-alpha/memory/project_tsp12_pgdump_blocked.md) — practical consequences of the SELECT-only rule
- [`services/mirror-worker-go/docs/reconciler.md`](../../services/mirror-worker-go/docs/reconciler.md) — invariants the comparator validates
- [ADR-0001](./0001-edge-persistence-intermittent-connectivity.md) — edge persistence (the comparator could later be reused at the edge for cloud-vs-edge drift)
