# edge-transformer

Not a service: a leftover directory from the rename of edge-transformer to **sparkplug-decoder**.
The live code is [`services/sparkplug-decoder`](../sparkplug-decoder/README.md).

## What it does

Nothing. The directory holds one file, `internal/agent/agentcfg/register_cpack_full_test.go`
(added 2026-09-02 in #601, a CPACK full-topology register fixture). There is no `go.mod` here, and the
file imports `services/edge-transformer/internal/agent/tenantprofile`, a package path that no
longer exists, so no Go module compiles or tests it. Its live counterpart package is
`services/sparkplug-decoder/internal/agent/agentcfg/`.

The old name survives in a few places, all of them pointing at sparkplug-decoder code:

| Where | What it is |
|---|---|
| `services/sparkplug-decoder/cmd/edge-transformer/` | the decoder's main package; the Dockerfile builds it as `/usr/local/bin/sparkplug-decoder` |
| `compose.onprem-edge.yml` service `edge-transformer` (container `onprem-transformer`) | image `packiot-sparkplug-decoder:local` with `LOCAL_DECODE_ONLY=true`: decodes the box's SparkPlug stream into the local current-state DB for `edge-dashboard` (ADR-0053) |
| env `EDGE_TRANSFORMER_MODE` | read by `services/sparkplug-decoder/internal/config/config.go`; today both modes behave the same (only the log line differs) |
| metric prefix `edge_transformer_` | the decoder's Prometheus metrics (e.g. `edge_transformer_amqp_acked_total`), kept to preserve dashboard and alert continuity |
| `.github/workflows/inspect-edge-transformer.yml` | "Inspect sparkplug-decoder (staging)", a manual read-only debug workflow; file name kept |

## Where it fits

N/A: not deployed. See [sparkplug-decoder](../sparkplug-decoder/README.md).

## Status and environments

N/A: nothing here is built or deployed in any environment.

## Interfaces

### HTTP

N/A.

### Messaging

N/A.

### Database

N/A.

## Configuration

N/A: no code reads configuration here.

## Run locally

N/A: the file cannot compile (no module, missing import path).

## Operating it

N/A. Before deleting the directory, note that `scripts/ci/packml-baseline.tsv` (ADR-0061 PackML
ratchet) lists the file, and `scripts/provision-cpack-replica-sandbox.sh` still points `ETSRC` at
`services/edge-transformer`.

## Code layout

| Path | What |
|---|---|
| `internal/agent/agentcfg/register_cpack_full_test.go` | orphaned test fixture (no module) |

## Related docs

- [sparkplug-decoder README](../sparkplug-decoder/README.md)
- [ADR-0053 — on-prem ingest edge for outage autonomy](../../docs/adr/0053-on-prem-ingest-edge-for-outage-autonomy.md)

<!-- wiki-links: added in cross-reference pass -->
