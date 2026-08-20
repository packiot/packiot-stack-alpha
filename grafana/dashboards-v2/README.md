# Packiot dashboards v2

Reviewed, rebuilt Grafana boards, loaded into a **separate "Packiot v2" folder**
(provider `packiot-v2`) so the original "Packiot" set is untouched during the
flip bake. **v1 retires once v2 is blessed** — A/B them side by side first.

Design contract + the live-verified metric universe: [`_SPEC.md`](./_SPEC.md).

## Why v1 had blank tiles (all fixed here)

- **Datasource-null** on v1 boards 07/08/09/10 → PromQL silently hit the default
  Postgres datasource and died. **v2 pins an explicit datasource on every panel
  AND every target.**
- **Phantom metric** `bake_tenant_converged` (queried by v1's flip gate + an
  alert, never emitted) → dropped; flip-readiness is **derived** from real
  `bake_surface_mismatches`/`bake_identity_mismatch`.
- **Scrape gaps** — `ingest-shim` + `operator-adapter` (the live Incoplast path)
  weren't scraped → jobs added in `monitoring/prometheus/prometheus.yml`.

## Reading a blank tile

Every v2 panel is one of three, and its `description` says which:

| A blank/zero tile means | Because |
|---|---|
| ✅ **real, currently zero** | e.g. an error-rate line — flat 0 is *healthy* |
| 🟡 **truthful-empty (gated/inert)** | the metric ships behind a flag or a retiring service; the description names the flag |
| 🔴 **would have been a bug** | fixed at the source (datasource, phantom, scrape) — should not recur in v2 |

If a tile is blank and its description doesn't explain it, that's a real signal —
check the source metric on the **Infra** board's `up`-by-job scrape-health table.

## Boards

| Board | uid | Answers | Notable expected-empties |
|---|---|---|---|
| **00 Overview** | `v2-overview` | Firing alerts + is-the-stack-alive + does-data-land, one glance | "Firing alerts" empty = nothing firing (good) |
| **03 OEE (business)** | `v2-oee` | OEE/A/P/Q per equipment, `$enterprise/$site/$area/$equipment` chain | SQL over `equipment_values`; cross-check vs the engine's `production_orders_runtime` (noted on each panel) |
| **04 Engine** | `v2-engine` | oeecloud-worker: AMQP→jobs→writes, `$tenant`/`$flow` | job error/panic rate flat 0 = healthy; `skipped_30700/30800_30899` are expected (config params handled elsewhere) |
| **05 Ingest** | `v2-ingest` | edge-transformer: MQTT→calc→emit→outbox | one annotated tile explains `commands_*`/`erp_*` read 0 by design (inert flags); `amqp_deliveries` not charted (unused in MQTT-in topology) |
| **06 Mirrors** | `v2-mirrors` | replay lag + comparator divergence + DLQ + fan-out | `comparator_oee_divergence_pct` = 0 means flows agree; DLQ depth 0 = healthy; retires at flip R1 (noted) |
| **07 Operator** | `v2-operator` | operator-adapter/ingest-shim request metrics + `user_logs` actions | adapter/shim metrics were just scraped — flat 0 right after deploy = scrape-lag, not silence (check `up{job=...}` on Infra) |
| **08 Logs** | `v2-logs` | Unified Loki, `$service`(dynamic)/`$level`/`$search` | `$service` is `label_values(service)` — never a hardcoded list; no `tenant` label on logs |
| **09 Equipment** | `v2-equipment` | Reference data — hierarchy, packml_register, POs, shifts | pure config browser (SQL) |
| **10 Infra** | `v2-infra` | host disk/mem/cpu, pg_up, go/process runtime, **scrape health** | the `up`-by-job table surfaces any target that stops being scraped |
| **16 Database DBM** | `v2-database-dbm` | Deep ("Datadog-style") DB internals on the **F3 plane** (`$datname`=`packiot_analytics`): session saturation, throughput/efficiency, table+index health, TimescaleDB jobs/cagg-lag/compression, per-tenant load | catalog-view panels (seq-scans, unused indexes, cagg lag, jobs, compression) are **native SQL over `packiot_analytics`** until postgres-exporter reloads the new queries; `pg_stat_statements` section is PENDING a DB restart (prereqs on the panel) |
| **17 Data Quality** | `v2-data-quality` | OEE-invariant violations from `data_quality_event` (F3) — `OEE_GT_1`/`NET_GT_GROSS`/`NEGATIVE_METRIC` by rule×enterprise×equipment; feeds P11 andon | native SQL over `packiot-postgres-shadow`; empty only if `DQ_ALARMS_ENABLED` never ran (641 violations present now) |
| **18 DB Query Traces** | `v2-query-traces` | **Tempo/TraceQL** — jump from a latency spike to the exact slow SQL trace; slow-DB-span table, p95/rate by service, saved by-table TraceQL + cookbook | span search works today; exemplar *dots* need per-service `trace_id` on `http_request_duration_seconds` (separate PR); `mirror-worker-go`/`shadow-mirror` untraced (retiring) |

### Retired boards

- **01 Replication** (`v2-replication`) and **02 Flip gate** (`v2-flip-gate`) were
  pure 3-flow / bake instruments. The flip gate is closed, so both were removed
  (2026-07). Their live-metric successors (`bake_surface_mismatches` etc.) still
  drive the alerts in `rules.yml`, kept until the ADR-0032 F2/shadow-mirror
  decommission prunes them in lockstep.

## Datasources (pinned on every panel)

`packiot-prometheus` · `packiot-loki` · `packiot-tempo` (traces / TraceQL) ·
`packiot-postgres` (F1+F2, DB `packiot`) · `packiot-postgres-shadow` (F3, DB `packiot_analytics`).

## Conventions

- Grafana 11 schema (`schemaVersion: 39`). Every panel + target carries an
  explicit `{type,uid}` datasource. `text` panels + `row` dividers don't query,
  so carry none.
- New `v2-*` uids → provision cleanly into the v2 folder without colliding with
  v1's uids. **Files are the source of truth** — export UI edits back to JSON or
  they're lost on the 10s reload.
- Every panel sets a unit + (for stats) thresholds; timeseries use table legends
  with `lastNotNull`/`mean`; tables color-code the meaningful column.

## Retiring v1 — DONE (2026-07)

v2 was blessed. The `packiot` provider block was removed from
`provisioning/dashboards/all.yml` and `grafana/dashboards/` (13 v1 boards) deleted.
The v1 set was a full duplicate that still carried dead
primary-api/back4-api/hasura panels + 3-flow/bake artifacts.
