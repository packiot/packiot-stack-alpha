# simulator/ — the Python two-layer simulator

**There are TWO simulators in this stack; this is the HTTP one.**

| | `simulator/` (this dir) | `plc-sim` (Go) |
|---|---|---|
| Language | Python (`simulator.py`) | Go (`services/edge-transformer/cmd/plc-sim`) |
| Path it drives | POSTs SparkPlug JSON to **edge-nodered** `/plc-data` (legacy HTTP ingest) | publishes SparkPlug B over **MQTT** to mosquitto (the 10.9 ingest) |
| Used by | all three compose files | `compose.staging.yml` only |
| Retirement | with the Node-RED leg (flip R6/R7 territory) | stays — it exercises THE ingest |

Two layers inside `simulator.py`:
1. **PLC layer** — reads active `packml_register` topics from the DB
   and emits metric payloads every `SIM_INTERVAL` (5s default).
2. **Operator layer** — rotates 3 users calling edge-api every
   `OP_INTERVAL` (15s): start/stop POs, justify downtimes — this is
   what keeps `user_logs` (and therefore shadow-mirror) exercised.

`devctl.py` — manual CLI to act as `dev.user` (fire one PO start, one
downtime, etc.) — handy for the consumer-smoke layer of
`docs/guides/manual-smoke-check.md`.

Env: `EDGE_NODERED_URL` · `EDGE_API_URL` · `DB_URL` · `SIM_INTERVAL` ·
`OP_INTERVAL`.

Calibration note: staging OEE > 1 artifacts trace to sim ideal-speed
calibration, not engine math — check here before suspecting the port.
