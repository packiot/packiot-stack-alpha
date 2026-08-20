# Packiot dashboards v2 — build spec

Reviewed, rebuilt Grafana boards. Loaded into a separate **"Packiot v2"** folder
(provider `packiot-v2` in `provisioning/dashboards/all.yml`) so the original
"Packiot" set stays untouched during the flip bake. v1 retires once v2 is blessed.

Every board here is **grounded in metrics verified live** (Prometheus series
counts checked against the running staging stack 2026-07-10) — no panel queries
a metric that doesn't exist. The whole reason v1 accumulated blank tiles was the
opposite; see "Bug classes" below.

## Hard rules (these are why v1 had blank tiles)

1. **Every panel AND every target pins an explicit datasource** `{"type","uid"}`.
   v1 boards 07/08/09/10 had `datasource: null` → Grafana fell back to the default
   Postgres datasource → PromQL died silently. Never rely on the default.
2. **No phantom metrics.** `bake_tenant_converged` is queried by v1 board 09 (the
   flip gate!) and an alert but is **never emitted in Go** (0 series live). v2
   derives flip-readiness from real `bake_surface_mismatches` / `bake_identity_mismatch`.
3. **A blank tile must be explained.** If a panel can legitimately read empty, its
   description says why (gated flag / healthy-zero / retires-at-flip). A zero must
   read as "healthy" or "inert", never "is this broken?".

## Datasource UIDs (exact — Grafana 11.5.0)

| Role | uid | Notes |
|---|---|---|
| Prometheus | `packiot-prometheus` | httpMethod POST |
| Loki | `packiot-loki` | |
| Postgres F1+F2 | `packiot-postgres` | **default**; DB `packiot`, schemas `public`(F1) + `shadow_go_port`(F2) |
| Postgres F3 | `packiot-postgres-shadow` | DB `packiot_shadow` (flip target) |

## Template variables (consistent across boards)

- `$tenant` — Prometheus label values of `oeecloud_worker_batch_writes_total` `tenant` (values: cpack, incoplast, simcorp, staging). edge-transformer carries `tenant` natively; oeecloud synthesizes it via relabel.
- `$flow` / `dest` — `f1_public` | `f2_shadow_go_port` | `f3_packiot_shadow`.
- `$service` — Loki label values of `service` (NOT a hardcoded list — use `label_values(service)`).
- `$level` — info|warn|error|debug. `$search` — free-text line filter.
- `$enterprise/$site/$area/$equipment` — SQL-driven chain on the OEE board.

## Live-verified metric universe (series count checked 2026-07-10)

✅ = has live series · 🟡 = truthful-empty (annotate) · 🔴 = was a bug (now fixed)

| Metric | State | Board |
|---|---|---|
| `oeecloud_worker_batch_writes_total{dest,tenant,result}` | ✅ 16 | Replication, Engine |
| `oeecloud_worker_job_ticks_total{job,outcome}` | ✅ 13 | Engine |
| `oeecloud_worker_amqp_deliveries_total{routing_key,result}` | ✅ | Engine |
| `oeecloud_worker_handler_duration_seconds` (histogram) | ✅ | Engine |
| `oeecloud_worker_writer_po_parameter_ops_total{op}` | ✅ | Engine |
| `oeecloud_worker_po_control_ops_total{op}` | ✅ | Engine |
| `bake_surface_mismatches{surface,enterprise}` | ✅ 19 | Flip gate |
| `bake_surface_compared{surface,enterprise}` | ✅ | Flip gate |
| `bake_identity_mismatch{surface}` | ✅ 3 | Flip gate |
| `bake_tenant_converged` | 🔴 0 (phantom) | **DO NOT USE** — derive from mismatches |
| `mirror_worker_comparator_oee_divergence_pct{id_production_order}` | ✅ 8 | Mirrors |
| `mirror_worker_cursor_lag_seconds` / `dlq_depth` / `reconciler_*` / `value_fanout_total{destination,outcome}` | ✅ | Mirrors |
| `edge_transformer_emitted_total{flow}` | ✅ 3 | Ingest, Replication |
| `edge_transformer_mqtt_connected` / `mqtt_received_total` / `mqtt_handle_errors_total` | ✅ | Ingest |
| `edge_transformer_shadowpub_{published,confirmed,nacked,in_flight}` | ✅ | Ingest |
| `edge_transformer_sparkplug_seq_gaps_total{group_id,edge_node_id,device_id}` | ✅ | Ingest |
| `outbox_depth` / `outbox_oldest_age_seconds` (unprefixed!) | ✅ 1 | Ingest |
| `calc_evaluations_total{tenant,kind,outcome}` + `calc_*` | ✅ 6 (USE_GO_PORT is ON) | Ingest |
| `edge_transformer_amqp_deliveries_total{routing_key,tenant,result}` | 🟡 0 | not used in staging's MQTT-in topology — annotate |
| `edge_transformer_commands_*{tenant,verb}` | 🟡 0 | ships inert (EDGE_COMMANDS_ENABLED off) — annotate |
| `edge_transformer_erp_*` | 🟡 0 | not wired (erpconnector inert) — annotate |
| `ingest_shim_requests_total{outcome}` | 🔴→✅ | scrape job added this PR (was unscraped) — Operator/Ingest |
| `operator_adapter_requests_total{action,outcome}` | 🔴→✅ | scrape job added this PR (was unscraped) — Operator |
| `shadow_mirror_*` | 🟡 | retires at flip R1 — annotate |
| `node_*` / `pg_up` / `pg_stat_database_numbackends` / `go_*` / `process_*` | ✅ | Infra/SLO |

## Board list (v2)

| File | uid | Replaces | Purpose |
|---|---|---|---|
| `00-overview.json` | `v2-overview` | 03+13 top | Firing alerts + stack-alive + does-data-land, one glance |
| `01-replication.json` | `v2-replication` | 13 | **Per-tenant F1/F2/F3 parity** — the Incoplast/CPACK replication proof |
| `02-flip-gate.json` | `v2-flip-gate` | 09 | Bake surfaces + identity (real metrics, no phantom) |
| `03-oee-business.json` | `v2-oee` | 01 | OEE per equipment (SQL, $enterprise chain) |
| `04-engine.json` | `v2-engine` | 08 | oeecloud-worker: AMQP→jobs→writes per flow/tenant |
| `05-ingest.json` | `v2-ingest` | 10 | edge-transformer: MQTT→calc→emit→outbox |
| `07-operator.json` | `v2-operator` | 05 | operator actions (user_logs SQL) + adapter/shim metrics |
| `08-logs.json` | `v2-logs` | 04+06+11 | unified templated Loki |
| `09-equipment.json` | `v2-equipment` | 02 | reference data (hierarchy, packml, POs, shifts) |
| `10-infra.json` | `v2-infra` | — (new) | node/pg/go exporters — nothing consumed them before |

New uids (`v2-*`) → these provision cleanly into the new folder without colliding
with v1's uids. All Grafana-11 schema. Panels use `overflow` scroll containers;
stat panels set unit + thresholds; timeseries set legend + tabular tooltips.
