# bispharma Node-RED connectivity flows (Tier-1)

This directory is mounted into the `nodered` container at `/data/flows-import`.

Place here:
- the client's **connectivity export** (PLC/OPC-UA/S7/Modbus I/O + shaping), and
- the generated **`../bispharma-tee-node.json`** imported onto the
  SparkPlug-assembly node (a *tee* — a second wire, not a redirect).

The tee forwards RAW suffix tags only. It must NOT publish `spBv1.0/*`
(the sparkplug-agent owns that namespace — ADR-0042 §2.3). It reads the ingest
key from the `BISPHARMA_INGEST_KEY` env var, never hardcoded.
