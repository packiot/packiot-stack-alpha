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
| **03 OEE (business)** | `v2-oee` | OEE/A/P/Q per equipment, `$enterprise/$site/$area/$equipment` chain | SQL over `equipment_values`; cross-check vs the engine's `production_orders_runtime` (noted on each panel); `$datasource` defaults to **F3** (equipment_values only lands fresh there post-flip) |
| **04 Engine** | `v2-engine` | oeecloud-worker: AMQP→jobs→writes, `$tenant`/`$flow` | job error/panic rate flat 0 = healthy; `skipped_30700/30800_30899` are expected (config params handled elsewhere) |
| **05 Ingest** | `v2-ingest` | edge-transformer: MQTT→calc→emit→outbox | one annotated tile explains `commands_*`/`erp_*` read 0 by design (inert flags); `amqp_deliveries` not charted (unused in MQTT-in topology) |
| **07 Operator** | `v2-operator` | operator-adapter/ingest-shim request metrics + `user_logs` actions | adapter/shim metrics were just scraped — flat 0 right after deploy = scrape-lag, not silence (check `up{job=...}` on Infra); `$datasource` defaults to **F1** — `user_logs` only ever lands there, never F3 (fixed 2026-08-20, see below) |
| **08 Logs** | `v2-logs` | Unified Loki, `$service`(dynamic)/`$level`/`$search` | `$service` is `label_values(service)` — never a hardcoded list; no `tenant` label on logs |
| **09 Equipment** | `v2-equipment` | Reference data — hierarchy, packml_register, POs, shifts | pure config browser (SQL); `$datasource` defaults to **F3** (the post-flip source of truth) |
| **10 Infra** | `v2-infra` | host disk/mem/cpu, pg_up, go/process runtime, **scrape health** | the `up`-by-job table surfaces any target that stops being scraped |
| **11 Database** | `v2-database` | Postgres/TimescaleDB via **Prometheus** (postgres-exporter): cache hit ratio, xact/tuple rates, connections by state, longest query, DB size, hypertable size/chunks/compression | depends entirely on postgres-exporter's scrape succeeding — see the queries.yaml collision fix below; was fully dark until 2026-08-20 |
| **12 API** | `v2-api` | RED (rate/errors/duration) for edge-api, read-api, operator-adapter/operator-gateway, ingest-shim via `http_request_duration_seconds_*` | `operator_adapter_requests_total` can read 0-series (not flat-0) right after an operator-gateway restart — the CounterVec only materializes a label combo after first use, unlike ingest-shim which pre-registers; self-heals once operator traffic flows |
| **13 Bus (RabbitMQ)** | `v2-rabbitmq` | `rabbitmq_global_messages_{received,delivered,redelivered}_total` via the built-in `rabbitmq_prometheus` plugin | live, confirmed |
| **14 Uptime & Containers** | `v2-uptime-containers` | cAdvisor container CPU/mem/net per container | live, confirmed (74 series) |
| **15 PO staleness gate** | `v2-po-staleness-gate` | ADR-0023 PO-route 409/traffic/latency (real, live edge-api RED metrics) + degrade-to-ALLOW rate (**not yet emitted** — ADR-0023 lists the gate as "Foundation, in flight") | traffic/latency/409 panels work today; the two degrade-to-ALLOW panels are truthful-empty until `po_gate_degraded_total` ships (annotated on the panels) |
| **16 Database DBM** | `v2-database-dbm` | Deep ("Datadog-style") DB internals on the **F3 plane** (`$datname`=`packiot_analytics`): session saturation, throughput/efficiency, table+index health, TimescaleDB jobs/cagg-lag/compression, per-tenant load | catalog-view panels (seq-scans, unused indexes, cagg lag, jobs, compression) are **native SQL over `packiot_analytics`**, unaffected by the postgres-exporter fix below; the Prometheus-sourced panels on this board (session/throughput/hypertable-size stats) were dark until 2026-08-20 same as board 11; `pg_stat_statements` section is PENDING a DB restart (prereqs on the panel) |
| **17 Data Quality** | `v2-data-quality` | OEE-invariant violations from `data_quality_event` (F3) — `OEE_GT_1`/`NET_GT_GROSS`/`NEGATIVE_METRIC` by rule×enterprise×equipment; feeds P11 andon | native SQL over `packiot-postgres-shadow`; empty only if `DQ_ALARMS_ENABLED` never ran (405 violations present in the last 7 days as of 2026-08-20) |
| **18 DB Query Traces** | `v2-query-traces` | **Tempo/TraceQL** — jump from a latency spike to the exact slow SQL trace; slow-DB-span table, p95/rate by service, saved by-table TraceQL + cookbook | span search works today (confirmed live); exemplar *dots* need per-service `trace_id` on `http_request_duration_seconds` (separate PR) |
| **19 Factory / OEE analysis** | `v2-factory-analysis` | The deep client-factory board — per-line/area/equipment OEE trends, PO timeline, data-quality cross-cut, all SQL over F3 (`packiot-postgres-shadow`) | native SQL over live F3 data (equipment_values, production_orders, equipment_runtime_shift all confirmed populated); links out to OEE/Equipment/Data-Quality boards |

### Retired boards

- **01 Replication** (`v2-replication`) and **02 Flip gate** (`v2-flip-gate`) were
  pure 3-flow / bake instruments. The flip gate is closed, so both were removed
  (2026-07). Their live-metric successors (`bake_surface_mismatches` etc.) still
  drive the alerts in `rules.yml`, kept until the ADR-0032 F2/shadow-mirror
  decommission prunes them in lockstep.
- **06 Mirrors** (`v2-mirrors`) read exclusively from `mirror_worker_*` metrics
  emitted by the `mirror-worker-go` service. That service was profile-gated OFF
  in `compose.staging.yml` on 2026-08-13 (`profiles: ["legacy-comparator"]` —
  retired migration-era F1/F3 fidelity watchdog, obsolete once CPACK cut over
  to the new stack). Confirmed live 2026-08-20: no `mirror-worker-go` container
  running, `up{job="mirror-worker-go"}` permanently 0, every one of the board's
  12 panels dark with zero path to recovery short of re-enabling the profile.
  Removed 2026-08-20 (`monitoring/prometheus/prometheus.yml`'s scrape job was
  commented out in the same pass, matching the compose service's own
  keep-but-disable posture — re-enable both together if `legacy-comparator`
  ever comes back).

### 2026-08-20 adversarial review — fixes applied

A full pass against live staging data (not just static JSON review) turned up
one high-blast-radius bug and a few smaller ones:

- **postgres-exporter was down** (`up{job="postgres-exporter"}=0`), dark-ing
  ALL of board 11, the Prometheus-sourced half of board 16, and the DB panel
  on board 10 — since before this review started. Root cause:
  `monitoring/postgres-exporter/queries.yaml` had custom query blocks literally
  named `pg_stat_user_tables` / `pg_stat_user_indexes` — the SAME names as
  postgres_exporter's own built-in collectors, but with different HELP text.
  The Prometheus client library aborts the ENTIRE `/metrics` response on a
  HELP-text mismatch (confirmed live via the exporter's own error body), so
  the whole exporter went `500` → Prometheus marked it `down` → every metric
  in the file died, not just the colliding ones. Neither dashboard actually
  consumed those two metrics via Prometheus (16-database-dbm gets the same
  data via native SQL instead), so they were pure duplication. **Fixed**:
  removed both blocks.
- **07-operator's `$datasource` variable defaulted to F3**, but `user_logs`
  (its core data — "Operator actions over time", "Per-user action log") has
  **zero rows, ever**, on F3 (confirmed: `count(*) FROM user_logs` = 0 on
  `packiot_analytics`, 322k+ on `packiot`). The variable's own label already
  said "F1 default" — the `current.value` just didn't match it. **Fixed**:
  default flipped to F1.
- **03-oee-business / 09-equipment** had the inverse mismatch — label said
  "F1 default" but `current.value` was already F3, which is actually the
  *correct* functional default for both (F3 is where `equipment_values` lands
  fresh post-flip). **Fixed**: relabeled to match reality instead of changing
  the value.
- **06-mirrors removed** — see "Retired boards" above.
- **`monitoring/prometheus/prometheus.yml`'s `mirror-worker-go` scrape job**
  commented out (permanently-down target, no container listening).
- **15-po-staleness-gate** — annotated the two degrade-to-ALLOW panels:
  `po_gate_degraded_total` has zero Go call sites in `services/`/`edge-api` as
  of 2026-08-20 (grep-verified) — it's a forward-looking metric for ADR-0023's
  in-flight gate, not implemented yet. The panels already use `or vector(0)` /
  render "No data" gracefully; this was a documentation gap, not a query bug.
- **All three `compose.*.yml`** referenced a `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`
  pointing at a v1 board file (`grafana/dashboards/01-oee-pipeline.json`) that
  was deleted from the repo when v1 retired in July — a month-old dead setting.
  Worse, **`compose.production.yml` and `compose.development.yml` never had the
  `dashboards-v2` bind mount at all** (only `compose.staging.yml` got that fix,
  2026-07-15) — meaning production Grafana has been provisioning **zero** of
  these 18 boards. Fixed all three: home path now points at `00-overview.json`,
  dead `./grafana/dashboards` mount replaced with `./grafana/dashboards-v2` in
  all three environments.
- A live, unrelated-to-this-review incident was also found and reported (not
  fixed here — out of scope for a read-only Grafana review): the running
  staging Grafana container was crash-looping on a datasource provisioning
  conflict from the recent F3 rename. See the review's final report / PR
  description for the live diagnosis and the human-actionable fix.

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
