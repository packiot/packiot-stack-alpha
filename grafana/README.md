# grafana/ — dashboards & provisioning

Dashboards are **file-provisioned** (`provisioning/dashboards/all.yml`, single
provider, 10s reload; UI edits allowed but files are the source of truth — export
back to JSON or lose the change on the next reload).

## Layout — grouped by audience, not by component

`foldersFromFilesStructure: true` maps each subdirectory to a Grafana folder:

- `dashboards/audience/` → folder **"audience"** — start here. Overview + the
  three persona boards (CS · Client health, Platform · SRE, Pipeline · Data eng).
- `dashboards/library/` → folder **"library"** — the deep component boards
  (engine, ingest, rabbitmq, database, infra, logs, traces, equipment, …), kept
  with their stable `v2-*` uids so `/d/<uid>` links still resolve.

**Canonical design + persona map + the hardproof method live in
[`../docs/ops/observability-persona-dashboards.md`](../docs/ops/observability-persona-dashboards.md).**
The library boards' build contract is [`dashboards/_SPEC.md`](./dashboards/_SPEC.md).

## Datasources (`provisioning/datasources/`)

- `packiot-postgres` (**default**; DB `packiot` — F1, legacy/corpse)
- `packiot-postgres-shadow` (DB `packiot_analytics` — the live medallion DB;
  uid kept across the F3 rename since every panel references it by uid)
- `packiot-prometheus`, `packiot-loki`, `packiot-tempo`

## Gates (run in CI)

- `scripts/lint-dashboards.py` — structure: every panel+target pins a known
  datasource uid; no phantom metric names. Recurses `dashboards/**`.
- `scripts/hardproof-dashboards.py` — behaviour: every Prometheus target returns
  a non-empty (or allowlisted healthy-empty) vector against a live Prometheus.
  A rendered tile is not a proven tile — this runs the query.
