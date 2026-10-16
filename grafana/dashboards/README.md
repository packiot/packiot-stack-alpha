# Packiot Grafana dashboards

Provisioned from this directory by `grafana/provisioning/dashboards/all.yml` into two
Grafana folders. Staging Grafana: `https://grafana.staging.packiot.app/d/<uid>` (SSO).

| Folder | Purpose |
|---|---|
| **Audience** (`audience/`) | One board per reader: overview, Customer Success, platform/SRE, data engineering, ingest debugging. Start here. |
| **Library** (`library/`) | Deep-dive boards per subsystem (engine, ingest, operator, database, API, RabbitMQ, data quality, traces). |

| Folder | File | uid | Title |
|---|---|---|---|
| Audience | `00-overview.json` | `v2-overview` | Overview |
| Audience | `01-cs-client-health.json` | `aud-cs` | ① CS · Client health |
| Audience | `02-platform-sre.json` | `aud-sre` | ② Platform · SRE |
| Audience | `03-pipeline-data.json` | `aud-data` | ③ Pipeline · Data eng |
| Audience | `04-ingest-debug.json` | `aud-debug-ingest` | 🔎 Ingest debug — why isn't a client's data arriving? |
| Library | `03-oee-business.json` | `v2-oee` | OEE — per equipment |
| Library | `04-engine.json` | `v2-engine` | Engine — stream-engine |
| Library | `05-ingest.json` | `v2-ingest` | Ingest — edge-transformer |
| Library | `07-operator.json` | `v2-operator` | Operator — actions & adapter |
| Library | `08-logs.json` | `v2-logs` | Logs — Loki |
| Library | `09-equipment.json` | `v2-equipment` | Equipment & reference data |
| Library | `10-infra.json` | `v2-infra` | Infra — host / DB / runtime |
| Library | `11-database.json` | `v2-database` | Database — Postgres / TimescaleDB |
| Library | `12-api.json` | `v2-api` | API — RED |
| Library | `13-rabbitmq.json` | `v2-rabbitmq` | Bus — RabbitMQ |
| Library | `14-uptime-containers.json` | `v2-uptime-containers` | Uptime & containers |
| Library | `15-po-staleness-gate.json` | `v2-po-staleness-gate` | PO staleness gate |
| Library | `16-database-dbm.json` | `v2-database-dbm` | Database — deep (DBM) |
| Library | `17-data-quality.json` | `v2-data-quality` | Data quality — OEE invariants |
| Library | `18-query-traces.json` | `v2-query-traces` | DB query traces — Tempo |
| Library | `19-factory-analysis.json` | `v2-factory-analysis` | Factory / OEE analysis |

Design contract and the verified metric universe: [`_SPEC.md`](./_SPEC.md). Changes are
linted in CI (`.github/workflows/dashboard-lint.yml`). The wiki's
[service catalog](../../docs/wiki/reference/service-catalog.md) links each service to its
board; update it when you add one.

## Reading a blank tile

Every panel is one of three, and its `description` says which:

| A blank/zero tile means | Because |
|---|---|
| ✅ **real, currently zero** | e.g. an error-rate line — flat 0 is *healthy* |
| 🟡 **truthful-empty (gated/inert)** | the metric ships behind a flag or a retiring service; the description names the flag |
| 🔴 **would have been a bug** | fixed at the source (datasource, phantom, scrape) — should not recur |

If a tile is blank and its description doesn't explain it, that's a real signal —
check the source metric on the **Infra** board's `up`-by-job scrape-health table.

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

## History

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
  Worse, **`compose.production.yml` and `the dev/ environment (ADR-0060; formerly compose.development.yml)` never had the
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
