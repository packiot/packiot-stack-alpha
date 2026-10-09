# CPACK reader-gen L6 dup-id fix — generator is the source of truth (#57 / #45)

**Date:** 2026-08-25 · **Scope:** BUILD + REGENERATE + VERIFY OFFLINE. **No deploy.**
Fixes the reader-generator defect that blocks the twin re-point (PR #906 P0) and
task #57 ("generator must properly contemplate the edge artifacts").

## Where the generator lives (committed)

`services/sparkplug-decoder/internal/agent/clientdescriptor/generate_reader.go` —
`(*Descriptor).GeneratePlcReaderFlow`. It is the SECOND consumer of the descriptor's
`plc:` block (the first is `GenerateClientYAML`), emitting the Node-RED reader flow
(artifact 6) via `cmd/onboard-gen`. **The generator is committed** (PR #705 merged;
32-bit read added by #810). The generator INPUT is the descriptor's `plc:` block in
`docs/clients/edge-deployment/cpack/cpack.descriptor.yaml` — **not** `cpack.plc.yaml`
(that is a human-readable mirror, untracked, different schema).

The running `:1880` flow (`edge-cpack-nodered`, `/data/flows.json`) is `GeneratePlcReaderFlow`
output — node ids `cpack_mb_*_read_*`, `cpack_reader_norm`, the `CPACK PLC reader` +
`CPACK customizations` tabs all match the generator byte-for-byte.

## The defect (dup-id) — front and centre

`readID` was `fmt.Sprintf("%s_mb_%d_read_%d", p, i, k)` where `k` was the **per-map**
tag index (`for k, t := range m.Tags`). A single Modbus endpoint (CPACK's `PLC_L6`) is
referenced by **five** `modbus_tag_map` entries — one per member — so `k` restarted at
0 for every member and the eight L6 reads collapsed onto **two** ids:

```
cpack_mb_0_read_0  ×5   (BREYER, POLYTYPE, PTH-consumed, RMH-consumed, TEXA-consumed)
cpack_mb_0_read_1  ×3   (PTH-processed, RMH-processed, TEXA-processed)
```

Node-RED requires globally-unique node ids and keeps only the LAST definition per id,
so **6 of 8 reads were silently dropped**; both survivors resolve to `adr=0` (TEXA), so
**only L6/TEXA polled** — BREYER/POLYTYPE/RMH/PTH went dark. This is the twin re-point
P0 block (only L6/TEXA reaches Calc).

**Reproduced from the committed descriptor** with the pre-fix generator — byte-identical
to the live `:1880` flow (`read_0 ×5, read_1 ×3`).

**Fix:** a per-ENDPOINT running counter (`readIdx`, incremented across all of the
endpoint's maps) → `cpack_mb_0_read_0..7`, every read node unique. (OPC-UA already used
a running `j`; S7 emits one `s7 in` node per endpoint — neither had the bug.)

## Regenerated flow — OFFLINE validation (no deploy)

`onboard-gen --descriptor …/cpack.descriptor.yaml` → `cpack-reader-flow.json`:

- **39 nodes, ZERO duplicate ids.** 8 L6 `modbus-read` nodes, ids `_read_0..7`.
- Every L6 read: `quantity=2` (32-bit, from `uint32` span — #810) + low-word-first
  combine `p[1]*65536+p[0]` (word_swap) in the normalize fn.
- S7 lines carry **canonical** vartable names + `DINT`; OPC-UA FLEXO present.
- Every production line emits BOTH its infeed (gross) and outfeed (net) count leaf.

### Oracle cross-check (live packiot40, SELECT-only, 2026-08-25 13:30)

Each L6 read's target register vs the live member totalizer:

| member.leaf | adr | reg value | oracle member | match |
|---|---|---|---|---|
| BREYER.Consumed/91 | 60 | 291,873,994 | 291,873,994 | ✅ |
| POLYTYPE.Consumed/93 | 10 | 283,614,412 | 283,614,412 | ✅ |
| PTH.Processed/95 | 50 | 104,196,868 | 104,196,868 | ✅ |
| RMH.Consumed/94 | 50 | 104,196,868 | 104,196,868 | ✅ |
| RMH.Processed/94 | 0 | 266,120,802 | 266,120,802 | ✅ |
| TEXA.Consumed/92 | 0 | 266,120,802 | 266,120,802 | ✅ |
| TEXA.Processed/92 | 0 | 266,120,802 | 266,120,802 | ✅ |
| PTH.Consumed/95 | 100 | (input) | (oracle gross empty) | n/a |

7/8 match the live oracle **to the digit**; magnitudes ~2.9×10⁸ confirm 32-bit reads
are mandatory. Per production line (L3/L4/L5/L6/L8/L10) both meter machines
(infeed gross + TEXA outfeed net) now emit — L6's four dead members are restored.

## Staging-tee capability (parameterized, off by default)

`--staging-tee` (or `GenerateOptions.StagingTee`) adds a 2nd POST branch off the
normalize function to a staging ingest front door. URL + CLOUD ingest key are read from
env (`CPACK_STAGING_TEE_URL` / `CPACK_STAGING_TEE_KEY`) — never baked; **inert until set**.
Default output is byte-identical to before (single output, `return msg;`).

## cpack.plc.yaml reconciliation

Canonicalised the stale S7 115/116/L5 numeric tag names (514/17/19A/…) → the descriptor's
canonical topics (matched by `DB1,<TYPE><offset>`); 24 resolved, 10 flagged UNRESOLVED
(no descriptor mapping — need a count-index capture). Header now points to the descriptor
as the machine SSoT.

## Flags / unproven

- **PTH Consumed/95 @ adr100 = InputRegister** kept (descriptor rationale: reg 100 > the
  holding qty-80 block). PR #906 (citing `cpack.plc.yaml`) called this a defect; the
  descriptor + live flow + oracle-empty-gross all say otherwise. **Not flipped** — needs a
  live L6/PTH capture to confirm holding-vs-input. NOT a generator defect.
- **S7 PTH ProdProcessed on L3/L4/L8/L10 = `int` (INT16)** in the descriptor (matches the
  legacy extract). The task suggested DINT to avoid 32767 saturation; the legacy reader
  reads these as INT16, so flipping would DIVERGE from the oracle. **Not changed** — needs
  PLC data-type confirmation.
- **Deploy-time env:** the generator's normalize fn reads `AGENT_INGEST_API_KEY` +
  `CPACK_AGENT_URL`; the live `:1880` hand-patch used `CPACK_INGEST_KEY`. Deploying the
  regenerated flow requires mapping the agent ingest key env accordingly.

## Readiness

The regenerated reader is correct and ready to deploy to `:1880` — deploying it changes
BOTH the prod new-stack feed and (after the cutover) the twin. **Not deployed here** (gated).
