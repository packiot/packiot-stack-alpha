# Sparkplug B parity harness

Cross-implementation parity test for ADR-0010's Sparkplug B decode spike.

## What this proves

Our Go decoder (`internal/sparkplug/`) encodes Sparkplug B binaries that decode identically in `sparkplug-payload` — the same npm library Node-RED's `node-red-contrib-sparkplug-payload` node wraps. This validates that the wire format is standard-compliant and Node-RED can consume anything we produce (and vice versa).

## Setup

Once per checkout, from the edge-transformer module root:

```bash
cd testdata/parity
npm install
```

## Run

From the edge-transformer module root:

```bash
go test -tags parity -run TestParity -v ./internal/sparkplug/
```

The `parity` build tag isolates this test — the default `go test` doesn't require Node.js.

## Expected output

```
=== RUN   TestParityGoEncodeThenNodeDecode
    parity_test.go:186: PARITY CONFIRMED: Node.js sparkplug-payload decoded Go-encoded payload identically
    parity_test.go:187:   3 metrics, timestamp=<...>, seq=42
    parity_test.go:188:   metric[0] value=12345 type=Int64
--- PASS: TestParityGoEncodeThenNodeDecode (0.08s)
PASS
```

## What this does NOT test (ADR-0010 Phase 1 follow-ups)

- **The reverse direction**: Node-encode + Go-decode. The same wire-format guarantee applies but is worth explicit coverage.
- **Real factory payloads**: These fixtures are Go-generated. Real bit-exact parity requires capturing binary Sparkplug B frames from a live factory MQTT broker + decoding in both.
- **Node-RED's runtime SparkPlug subflow output shape**: `sparkplug-payload` at the library level is not exactly what the subflow surfaces to downstream nodes; the subflow massages the payload further. Full end-to-end parity requires an integration test against a running Node-RED, not just the library.

## Why `sparkplug-payload@^1.0.3` specifically

This is Eclipse Tahu's canonical JS Sparkplug B payload library. Node-RED's `node-red-contrib-sparkplug-payload` node wraps it directly with no protocol-level transformation. Comparing against this library is therefore comparing against the exact bytes Node-RED sees.

Version 1.0.3 was the latest at 2026-06-30. Later versions should be drop-in compatible; if parity breaks after a version bump, the ADR-0010 governance discipline says: pin the version, open a wire-format-drift ticket.
