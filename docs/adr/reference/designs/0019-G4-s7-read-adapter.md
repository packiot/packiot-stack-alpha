# Design Note — S7 Read Adapter + Tag→PackML Mapping (ADR-0019 G4, task S1/#32)

## Problem

Real Incoplast factory PLCs are **Siemens S7** (S7-300/400/1200/1500). The
edge-transformer only ingests **MQTT/SparkPlug B** today (plus `plc-sim`), so a
real S7 line cannot be onboarded — the last gap between staging's simulated
tenants and a production client-facing setup. ADR-0019 §G4 named the schema
side of this (`plc.endpoints[].rack/slot`); this note specs the *reader*.

## Decision: an S7 adapter is a SparkPlug PRODUCER, not a new hot-path seam

The cleanest, most faithful design mirrors `plc-sim` exactly: a standalone
binary that **reads S7 → maps tags to PackML metric names → publishes SparkPlug
B over MQTT** (retained NBIRTH alias table on connect, alias-only NDATA per
tick). The entire `edge-transformer` decode→transform→publish pipeline then
consumes it **unchanged**. This literally makes a real S7 line "look like a
production client" to the rest of the stack — the stated onboarding goal — and
keeps the change 100% additive (the MQTT path is untouched).

Rejected alternative: an in-process input seam inside `edge-transformer`. It
would couple PLC I/O to the transformer lifecycle and duplicate the SparkPlug
encode the pipeline already does. The producer approach reuses `plc-sim`'s
proven protocol shape (the decoder + StateStore were parity-checked against it).

## Library: `github.com/robinson/gos7` (BSD-3, pure Go)

gos7 is a clean-room S7comm client — **not** a CGo binding to libsnap7 — so the
`CGO_ENABLED=0` static/distroless build and the small CGo-free dependency set
(ADR-0009 discipline) are preserved. BSD-3 licensed; no LGPL inheritance.
Fallback if legal review stalls: `gopcua/opcua` (MIT, pure Go) — `_schema.yaml`
already lists `opcua` as a protocol, and Incoplast's older lines are OPC-UA.

## Shape

- `internal/s7/decode.go` — pure big-endian S7 value decoders (INT/DINT/REAL/
  BOOL), bounds-checked, unit-testable against known byte buffers.
- `internal/s7/client.go` — gos7 wrapper: `Connect(ip, rack, slot)` /
  `Read(db, start, size)` / `Close`, with redial-on-error (mirrors the MQTT
  subscriber's reconnect discipline). One session per poll loop (gos7 handlers
  are not goroutine-safe).
- `internal/s7/poller.go` — `Tag` (S7 address ↔ PackML metric name + alias),
  `Poller.Sample/EncodeBirth/EncodeData`. Groups tags by DB (one `AGReadDB` per
  DB per tick), decodes, scales, emits `SimMetric`s. Re-births on read-failure
  recovery so the StateStore never sees DATA-before-BIRTH.
- `cmd/s7-reader/main.go` — the producer binary (mirrors `plc-sim`): MQTT
  connect → NBIRTH → tick loop reads S7 → NDATA.

## Phasing

- **PR 1 (this change):** foundational adapter — one endpoint, a **hardcoded**
  tag set for one Incoplast machine (NOVOFLEX_15) read from a single DB, plus
  decoders/poller/client + tests + Dockerfile binary. Proves S7 → pipeline.
- **PR 2:** replace hardcoded tags with the per-tenant `client.yaml`
  `s7_tag_map` (extend `internal/clientconfig`; endpoints reuse the existing
  `PLC`/`PLCEndpoint` rack/slot scaffold; `host_ref` must be a `secret://`
  reference — never an inline IP, per the Incoplast cleartext-credential lesson).
- **PR 3:** feature flag + compose service (mirror `plc-sim`) + integration test
  against a Snap7 soft-PLC.

## Verification

Point `s7-reader` at a Snap7 soft-PLC (or the real read-only factory PLC),
confirm `edge-transformer` (MQTT enabled) decodes the stream and publishes
`sparkplug.data` envelopes — the smallest end-to-end slice proving the concept.

## Risks / notes

- S7 addressing correctness (big-endian, BOOL bit-offset, DB vs M/I/Q) — covered
  by unit tests on the pure decoders.
- NBIRTH alias discipline — re-publish retained NBIRTH on every reconnect.
- Secrets: PLC host via `secret://` only (PR 2).
