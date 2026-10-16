# CPACK — unresolved counter registers (factory-capture target list)

**Purpose.** A precise, address-first target list for a **live factory PLC count-index
capture** on the CPACK edge box (`packiot@10.135.1.173`), so every polled register that
could be a production counter is either **bound** to a `Prod*Count` topic or **positively
classified as junk** (version / status / digital I/O). Until each `UNRESOLVED` address is
resolved, the generated reader either drops it (no topic) or, worse, a mis-decode can leak a
non-production register into `gross` — the failure mode behind the CPACK line-OEE distortions
(#253, and the L5 gross spike below).

**Scope.** This is the residual gap after #601/#909/#916 fixed the confirmed line meters.
It does **not** touch `packiot40` / legacy. It is the last edge-config item standing between
CPACK and a "Bispharma-clean" onboarding (0 clamps). See
[onboarding-acceptance-checklist.md](onboarding-acceptance-checklist.md) Gate 5.

---

## 0. Why this exists — the decode contract

The generated reader binds a PLC address → a SparkPlug topic via the descriptor's
`s7_tag_map` (matched by `DB1,<TYPE><offset>` address). The decoder then reads the topic's
`Prod*Count` substring + `***TRIG` suffix to assign a counter **kind**
(`services/sparkplug-decoder/internal/transforms/calc_production_counters/decision_tree.go`):

| Topic shape | Decoded kind | Feeds |
|-------------|--------------|-------|
| `ProdConsumedCount …***TRIG_C=O` | infeed / gross | line **gross** |
| `ProdProcessedCount …***TRIG_C=I` | outfeed / net | line **net** |
| `…***TRIG_CS` | `Defective = Consumed − Processed` | **scrap** (flow-derived) |
| `ProdDefectiveCount` | defective | **scrap** (co-located) |

An address with **no `s7_tag_map` entry** carries only a stale numeric name (e.g. `583`,
`19A`). The reader cannot assign a kind. Two outcomes:
- **Benign:** the reader emits nothing for it (topic unknown) → no effect. This is the
  common case and why CPACK still mostly works.
- **Harmful:** if that address holds a fast-climbing value (a runtime-ms accumulator, a
  byte counter, a shared serial register) and a future descriptor edit binds it to the
  wrong `Prod*Count`, it inflates gross/net. This is the class the capture must *close on
  purpose*, not by accident.

**The register is the source of truth, not the name.** A live capture reads the actual
value trajectory of each address over a running shift; a counter climbs monotonically at
the production cadence, a version constant is flat, a status word toggles. That trajectory
is what binds (or rejects) each address.

---

## 1. Live symptom that motivates the priority order (staging, ent 3)

`gold.equipment_oee_shift`, id_equipment 47 = **L5** (F3 id), daily gross/net:

| Day | gross | net | "scrap" | reading |
|-----|------:|----:|--------:|---------|
| 2026-09-03 | 5,720,287 | 4,815 | 5,715,472 | gross ≫ net — **register anomaly** (near-zero real net, gross exploded) |
| 2026-09-04 | 6,293,982 | 4,111 | 6,289,871 | same |
| 2026-09-05 | 3,143,482 | 3,143,482 | 0 | gross==net (Q=1) |
| 2026-09-06 | 1,567,842 | 1,567,842 | 0 | gross==net |
| 2026-09-07…09 | ~60–80k | ==gross | 0 | small, clean |

30-day totals: L5 gross **43.0M** vs net **5.6M** (Q=0.13) — the oracle reference is
~9.6M gross / 45d (`cpack-reject-counter-role-analysis.md` §2). L5 gross is inflated ~4×,
driven almost entirely by the 09-03/09-04 spike where net was ~0. **L5 is also the PLC
carrying the most `UNRESOLVED` DINT registers** (below). Priority 1.

> Net>gross at the shift grain is currently **0 across all CPACK lines** (post-#253 drain +
> `LEAST` bound + backfill). The residual distortion is **gross over-count** (fake scrap),
> not net>gross — i.e. an *inbound register* problem, exactly what this capture targets.

---

## 2. UNRESOLVED register inventory (from `cpack.plc.yaml`)

Classified by whether the address type/position makes it a **counter candidate** (32-bit
`DINT` in the count block) or **junk** (`INT48` = the VERSION slot on every PLC; `X####.#` =
a digital I/O bit). Capture the candidates; document the junk so no one re-opens them.

### 2a. Counter candidates — CAPTURE THESE

| PLC (endpoint) | Address | Stale name | Type | Why a candidate | Capture priority |
|----------------|---------|-----------|------|-----------------|------------------|
| **S7 L5** (10.135.16.117) | `DB1,DINT8`  | `19A` | DINT32 | sits between POLYTYPE `/62` (DINT4) and RMH `/64` (DINT20) — a line-member count slot | **P1** |
| **S7 L5** (10.135.16.117) | `DB1,DINT12` | `19B` | DINT32 | same block, next slot | **P1** |
| **S7 L5** (10.135.16.117) | `DB1,DINT16` | `609` | DINT32 | same block, immediately before RMH `/64` | **P1** |
| **S7 116** (10.135.16.116) | `DB1,DINT8`  | `583` | DINT32 | first of four consecutive DINTs at the head of the CELULA2 block, before PTH40-03 `/339` | **P2** |
| **S7 116** (10.135.16.116) | `DB1,DINT12` | `584` | DINT32 | consecutive count slot | **P2** |
| **S7 116** (10.135.16.116) | `DB1,DINT16` | `585` | DINT32 | consecutive count slot | **P2** |
| **S7 116** (10.135.16.116) | `DB1,DINT20` | `586` | DINT32 | consecutive count slot | **P2** |

### 2b. Junk — DOCUMENT, do not capture as counters

| PLC | Address | Stale name | Reason it is junk |
|-----|---------|-----------|-------------------|
| S7 115 | `DB1,INT48` | `606` | `INT48` is the firmware VERSION slot on every CPACK PLC (see S7 116/L5/L8/L10/L4/L3 all carry `VERSION` at `DB1,INT48`). Flat constant. |
| S7 L5 | `DB1,INT48` | `VERSION` | VERSION slot (already named). |
| S7 L5 | `DB1,X1024.7` | `19S` | Bit address (`X` = digital), same family as L4's `I0..I4` @ `X1024.0-4` machine-status inputs. Not a totalizer. |

---

## 3. Known faithful gaps — NOT a capture target (leave alone)

These are already understood; capturing/re-mapping them **re-creates a phantom**. Documented
so the capture engineer does not "helpfully" close them.

| Line | Gap | Why leave it |
|------|-----|--------------|
| **L3 line gross** | BREYER's real *gross* (infeed) register is not mapped. `DB1,DINT0` on PLC L3 holds BREYER **ProcessedCount/76** (net), reverted 2026-08-26. | #909 tried mapping `DINT0` as `ProdConsumedCount/76` → fabricated ~44k line gross on a day the oracle L3 was fully idle. **Re-flipping re-creates the phantom.** L3 line gross stays a faithful gap until BREYER's true infeed register is found on a *different* address by capture. |
| **FLEXO** | Infeed-only OPC-UA `totalMeterCounter`. No outfeed/defective meter exists. | Q=1 is *structural* (single meter), not a register gap. Fix is presentation ("no scrap data"), not capture. |
| **SLEEVE1 / SLEEVE2** | `ProdProcessedCount`-only (net-only single meter). | Same — single meter, Q=1 structural. Presentation fix. |

---

## 4. Capture procedure (per candidate address)

The box tees live to both stacks, so this is a **read-only observation** on the running
factory PLC — no write, no legacy touch.

1. **Snapshot the address trajectory.** On the edge box, poll each candidate address every
   poll-interval for ≥ 1 full producing shift and log `(ts, raw_value)`. (Reuse the reader's
   S7 client in observe mode, or `snap7`/`python-snap7` read-only against the same
   `endpoint/rack/slot`.)
2. **Classify the trajectory:**
   - **Monotonic climb at production cadence** → a real counter. Determine kind by *where it
     sits in the serial train* (infeed member vs outfeed) and whether its climb matches an
     already-mapped meter's differential. Cross-check against the **legacy oracle**
     (`packiot40` @ 18.220.223.110, read-only) the same way §CANONICAL line meters were
     proven — the physical meter is the member whose full-window totalizer byte-matches.
   - **Flat / near-flat** → version or config constant → junk.
   - **Bounded oscillation / resets** → status/speed/register, not a totalizer → junk.
3. **Bind or reject in the descriptor** (`edge-deployment/cpack/cpack.descriptor.yaml`
   `s7_tag_map` — the generator SSoT, **not** `cpack.plc.yaml` which is the human mirror):
   - counter → add the canonical `CPACK/…/Prod{Consumed,Processed,Defective}Count/<idx>/Unit`
     topic with the correct `***TRIG` suffix, matched by address.
   - junk → add a comment binding it to a non-count name so the suffix-matcher stops
     re-flagging it.
4. **Regenerate + redeploy** the reader (`cmd/onboard-gen`), then **re-run Gate 5** of the
   acceptance checklist over a fresh shift: 0 net>gross, gross within ~Nx of the oracle,
   Q ∈ (0,1], no clamp fires.

---

## 5. Definition of done

CPACK is "counter-clean" (Gate 5 green) when:
- All §2a candidates are **bound to a `Prod*Count` topic or classified junk** in the
  descriptor (no `UNRESOLVED` comment remains for a DINT in a count block).
- L5 30-day gross is back within ~1.5× of the oracle differential (no 09-03/04-class spike
  recurs over a fresh soak).
- The §3 faithful gaps are **still gaps** (unchanged) — verified L3 line gross did not
  fabricate against an idle-oracle window.
- 0 totalizer-spike clamp fires and 0 net>gross rows over ≥ 2 producing shifts.

---

### Evidence appendix
- Register inventory: `docs/clients/cpack.plc.yaml` (the `UNRESOLVED` comments).
- Generator SSoT: `docs/clients/edge-deployment/cpack/cpack.descriptor.yaml` (`s7_tag_map`).
- Oracle line meters (differential method + L3 phantom): `docs/clients/cpack-legacy-oracle-line-meters.md`.
- Scrap model (why reject-role stays NULL): `docs/clients/cpack-reject-counter-role-analysis.md`.
- Decoder kind assignment: `services/sparkplug-decoder/internal/transforms/calc_production_counters/decision_tree.go`.
- Live L5 anomaly: `gold.equipment_oee_shift` ent 3 id_equipment 47, staging `packiot_analytics` (box `i-064bb36d1c454d861`), captured 2026-09-09.
