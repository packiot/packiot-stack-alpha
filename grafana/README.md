# grafana/ — dashboards & provisioning

Dashboards are **file-provisioned** (`provisioning/dashboards/all.yml`
→ folder "Packiot", 10s reload; UI edits allowed but files are the
source of truth — export back to JSON or lose the change).

Datasources (`provisioning/datasources/`): `packiot-postgres`
(**default**; staging TimescaleDB on the DB EC2), `packiot-postgres-shadow`
(the F3/consolidation DB), `packiot-prometheus`, `packiot-loki`.

## Board map

| # | uid | What it answers |
|---|---|---|
| 01 | `oee-pipeline` | is OEE data flowing, live |
| 02 | `equipment-config` | equipment & PackML routing state |
| 03 | `system-health` | DB & pipeline health |
| 04 | `packiot-logs` | stack overview (logs) |
| 05 | `packiot-operator` | operator activity |
| 06 | `packiot-services-logs` | per-service logs |
| 07 | `mirror-worker-flow` | prod in → replay/fan-out out |
| 08 | `oeecloud-worker-flow` | AMQP in → engine → writes per flow |
| **09** | **`bake-flow-parity`** | **THE FLIP GATE** — legacy F1 vs Go F2: 10 fidelity surfaces + 3 identity fingerprints |
| 10 | `edge-transformer-ingest` | MQTT in → Calc → triple-emit out |
| 11 | `packiot-pipeline-logs` | plc-sim → edge-transformer logs |
| 12 | `packiot-prometheus` | equipment_values fan-out (ADR-0012 data plane) |
| 13 | `database-reach` | what actually lands on F1 / F2 / F3 |

**The 09 discipline**: every non-zero parity reading must carry a
*named, dated* cause (the known-noise ledger lives in ADR-0016 +
session memory). A new unexplained non-zero is the only alarm that
matters. The 7-day flip gate reads this board — treat edits to 09 as
production changes.

Reading order when triaging: 13 (does data land?) → 08/10 (which hop?)
→ 09 (is it *correct*?) → 06/11 (logs for the guilty hop). Same
layering as `docs/guides/manual-smoke-check.md`.
