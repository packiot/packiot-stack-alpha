# CPACK "fake-perfect Quality" — reject-counter role analysis (2026-08-21)

**Question posed:** OEE Quality = net/gross reads Q=1.000 on most CPACK lines. Is that
because the REJECT/scrap counter role is unresolved (`packml_register.id_rejectcounter`
NULL → the name-suffix fallback finds no reject tag → net==gross)? If CPACK really measures
scrap, wire `id_infeedcounter/id_outfeedcounter/id_rejectcounter` for ent 3 and enable
`COUNTER_ROLES_FROM_DB`. If not, document that Q=1 is faithful.

**Verdict: CPACK DOES measure scrap, and it does NOT use the reject-counter role to do so.**
The `id_rejectcounter` columns should stay NULL for CPACK. The premise "Q=1.000 on most lines"
is also no longer true on staging — most producing lines already report a real Q<1. Wiring a
reject role would be fabrication and a no-op at best (double-attribution risk at worst).

---

## 1. How CPACK actually measures scrap (two native mechanisms, no role needed)

CPACK's scrap never arrives as a *separate machine's* `ProdDefectiveCount` stream that must be
re-attributed to a line — the shape the `id_rejectcounter` role exists to solve. It arrives on
the **same** equipment as the throughput counters, via two paths the decoder handles natively
through its `Prod*Count` + `***TRIG` name convention
(`services/sparkplug-decoder/internal/transforms/calc_production_counters/decision_tree.go`):

### (a) Flow-derived scrap via `***TRIG_CS` on the serial LINHAS lines
The LINHAS lines (L3/L4/L5/L6/L8/L10) are serial trains (BREYER/RMH/PTH infeed →
POLYTYPE → TEXA outfeed). Each outfeed stage's tag carries a `***TRIG_CS` suffix, which the
decoder reads as **`Defective = Consumed − Processed`** (`decision_tree.go` `TrigCS`). The
infeed stages carry `***TRIG_C=O` (`Processed := Consumed`, no scrap at infeed); the outfeed
stages carry `***TRIG_C=I`/`***TRIG_CS`. So scrap is the throughput difference across the
line, computed at decode — no dedicated reject counter, no role column.

Evidence: `docs/clients/cpack.plc.yaml` (every outfeed count tag carries `***TRIG_CS`; L6
block header: "scrap between stages is captured by `***TRIG_CS` (defective = consumed −
processed)"); legacy oracle differential (`docs/clients/cpack-legacy-oracle-line-meters.md`)
shows the real ~10% scrap on L6 outfeed machines.

### (b) Native `ProdDefectiveCount` tags on the CELULA single-machine lines
The **live factory agent** (`/home/packiot/cpack-edge/cpack/cpack-agent.yaml` on
10.135.1.173, read 2026-08-21) maps a `ProdDefectiveCount` metric for a large set of
single-machine equipments — CER400, DUBUTI1, DUBUTI2, HOTMADAG, ISIMAT, BREYER1, BREYER2,
POLYTYPE1, POLYTYPE2, PTH80S … (the repo snapshot `docs/clients/cpack-agent.yaml` only had
one — the factory map has since grown). These decode straight to `CounterKindDefective` by the
`ProdDefectiveCount` substring rule (`decision_tree.go:60`). Staging `packml_register` confirms
~12 `ProdDefectiveCount` topics registered for ent 3 (L3=3, L4=1, L5=2, CELULA1/2 machines).

**Neither path uses `id_rejectcounter`.** That column would only matter if a line's scrap lived
on a *different* `id_equipment` than the line (split instrumentation — e.g. the bispharma
`counter168/169` shape in `docs/clients/bispharma-oee-mapping-fix.md`). CPACK's scrap is
co-located with its throughput, so the built-in name/TRIG convention already resolves it.

---

## 2. Current live Quality — the "most lines Q=1.000" premise is stale

`equipment_runtime_shift`, ent 3, tp=3 lines, last 45 days (staging box
`i-06c9547a2c7091ab7`, F3 `packiot_analytics`, `Q = Σnet / Σgross`):

| Line | shifts | gross | net | scrap | Q | scrap source |
|------|-------:|------:|----:|------:|--:|--------------|
| L5 | 177 | 9,654,440 | 6,799,060 | 2,855,380 | **0.7042** | TRIG_CS flow |
| PTH40-03 | 177 | 393,088 | 212,533 | 180,555 | **0.5407** | ProdDefectiveCount / flow |
| PTH80S | 177 | 288,596 | 226,147 | 62,449 | **0.7836** | ProdDefectiveCount |
| L6 | 177 | 1,248,390 | 1,080,740 | 167,648 | **0.8657** | TRIG_CS flow |
| L10 | 177 | 1,138,820 | 1,044,530 | 94,284 | **0.9172** | TRIG_CS flow |
| L3 | 177 | 7,430,240 | 7,138,280 | 291,951 | **0.9607** | TRIG_CS flow |
| L8 | 177 | 6,035,570 | 5,893,730 | 141,833 | **0.9765** | TRIG_CS flow |
| ISIMAT | 177 | 380,558 | 373,616 | 6,942 | **0.9818** | ProdDefectiveCount |
| L4 | 177 | 7,030,600 | 6,941,330 | 89,276 | **0.9873** | TRIG_CS flow |
| HOTMADAG | 177 | 489,793 | 484,948 | 4,845 | **0.9901** | ProdDefectiveCount |
| DUBUIT2 | 177 | 217,679 | 217,654 | 25 | 0.9999 | ProdDefectiveCount (near-zero window) |
| POLYTYPE2 | 177 | 173,590 | 173,570 | 20 | 0.9999 | ProdDefectiveCount (near-zero window) |
| BREYER2 | 177 | 362,768 | 362,768 | 0 | 1.0000 | has Defective tag → faithful zero |
| CER400 | 177 | 47,822 | 47,822 | 0 | 1.0000 | has Defective tag → faithful zero |
| FLEXO | 177 | 2,407,860 | 2,407,860 | 0 | 1.0000 | **single meter (OPC-UA infeed only)** |
| SLEEVE1 | 177 | 516,023 | 516,023 | 0 | 1.0000 | **single meter (net-only)** |
| SLEEVE2 | 177 | 915,311 | 915,311 | 0 | 1.0000 | **single meter (net-only)** |

**12 of 17 producing lines already show a real Q<1** with measured scrap. Only 5 read
Q=1.000 — and that is not a reject-role gap:

- **BREYER2, CER400** — HAVE a `ProdDefectiveCount` tag; scrap was genuinely 0 in the window
  (single-machine converting/labeling that runs at ~100% good). **Q=1 is faithful.**
- **FLEXO** — OPC-UA `totalMeterCounter` with `***TRIG_C=O` — an **infeed-only single meter**
  (`cpack.plc.yaml:160`). No outfeed/defective tag exists to difference against → `net:=gross`
  by the decoder's "gross-only" rule → Q=1 **structurally**. There is no second measurement to
  make; Q=1 is not a claim of perfection.
- **SLEEVE1, SLEEVE2** — `ProdProcessedCount`-only with `***TRIG_C=I` (`cpack.plc.yaml:155-156`)
  — **net-only single meter**. Legacy "N-only ⇒ gross:=net, scrap=0" convention → Q=1
  structurally.

Where the old permanent-Q=1.0 fault *did* exist (outfeed machines reading net==gross every
row), it was already root-caused and fixed — a **reader** defect, not a role gap: the
csadmin/ADR-0045-generated Node-RED reader read 32-bit totalizers as single 16-bit and
defaulted `qty=1`, so `ProdProcessedCount` mirrored `ProdConsumedCount` → scrap 0 → Q pinned
at 1.0. Fixed via the reader generator (`qty=2` + low-word-first combine) and the
infeed/outfeed line-meter mapping. See `docs/clients/cpack-legacy-oracle-line-meters.md`
("ROOT CAUSE PINNED — reader duplicates consumed→processed" and "DEPLOYED LIVE + VALIDATED").
The Q<1 table above is that fix working.

---

## 3. Why we are NOT wiring `id_rejectcounter` (or the infeed/outfeed roles) for CPACK

1. **Reject role is inapplicable.** `id_rejectcounter` re-routes a *source machine's*
   `ProdDefectiveCount` stream onto *another* equipment's (line's) scrap role. CPACK's scrap is
   co-located (same machine, or flow-derived on the line), already resolved by the decoder's
   name/TRIG convention. There is no separate reject machine to point at → nothing correct to
   populate. Filling it in would be **fabricating** a topology that doesn't exist.

2. **It would be a no-op at best, double-count at worst.** `COUNTER_ROLES_FROM_DB` is in fact
   **already `true`** on the staging decoder (the brief's "currently OFF" is stale — verified via
   `docker inspect sparkplug-decoder`). With all role columns NULL the resolver builds zero
   bindings — a safe no-op. Populating them would activate the decode-time re-attribution path
   **on top of** the already-live line-meter path (`PHASE9_LINE_AGG_ENABLED=true` +
   `line_param30700_seed.go`, which reads the *same* `id_infeedcounter/id_outfeedcounter`
   columns), risking two writers attributing the same counter. That is worker/rollup territory
   (out of scope here) and should not be switched on blind.

3. **The data is already correct.** 12/17 lines report real yield. Turning on a second
   attribution mechanism to "fix" a Q that is already <1 would regress, not help.

---

## 4. The one real follow-up: presentation, not data (single-meter lines)

Three lines are genuinely **single-meter** and can never compute a real Quality:
**FLEXO** (infeed-only OPC-UA), **SLEEVE1**, **SLEEVE2** (net-only). Their Q=1.000 is a
structural artifact of having one counter, not a measured 100% yield. Surfacing "100% Quality"
for them is misleading.

**Recommended fix (front4 / Superset presentation layer, not the calc):** when a line has only
one throughput meter (no `ProdDefectiveCount` tag AND not both a gross and net meter), render
Quality as **"no scrap data"** / **"—"** instead of "100%". The signal already exists in the
data: `equipment_values.scrap_incr` is uniformly 0 AND the line has a single registered
count-role. This is the same "make absence legible / NULL ≠ 0" lesson from
`docs/clients/cpack-counter-semantics-audit.md`.

For BREYER2/CER400 (have a defective tag, momentarily zero scrap) Q=1.000 is faithful and
should display normally — those are real 100%-good windows.

---

## 5. Instrumentation summary

| Class | Lines | Scrap measured? | Q |
|-------|-------|-----------------|---|
| Serial LINHAS (TRIG_CS flow) | L3, L4, L5, L6, L8, L10 | Yes (consumed−processed) | Real, <1 |
| Single-machine w/ Defective tag | PTH40-03, PTH80S, HOTMADAG, ISIMAT, DUBUIT2, POLYTYPE2, BREYER2, CER400 (+ BREYER1, DUBUTI1, POLYTYPE1 per factory agent) | Yes (`ProdDefectiveCount`) | Real (1.0 only when window scrap=0) |
| Single-meter (infeed-only) | FLEXO | No (no second meter) | 1.0 structural → label "no scrap data" |
| Single-meter (net-only) | SLEEVE1, SLEEVE2 | No (no second meter) | 1.0 structural → label "no scrap data" |

**Bottom line:** CPACK measures scrap through native co-located instrumentation
(`ProdDefectiveCount` tags + `***TRIG_CS` flow derivation). No `id_rejectcounter` wiring is
warranted; the columns stay NULL. The residual Q=1.000 lines are either faithful (real zero
scrap) or genuinely single-meter, where the fix is presentation ("no scrap data"), not data.

---

### Evidence appendix
- Decoder TRIG semantics: `services/sparkplug-decoder/internal/transforms/calc_production_counters/decision_tree.go` (`TrigCS`=Defective=Consumed−Processed; `TrigCEqualsO/I`; `ProdDefectiveCount`→`CounterKindDefective`).
- Role resolver (unused for CPACK): `services/sparkplug-decoder/internal/counterroles/counterroles.go` (role 3 = reject/Defective); gated by `COUNTER_ROLES_FROM_DB`.
- Factory agent Defective map: `/home/packiot/cpack-edge/cpack/cpack-agent.yaml` (10.135.1.173, read-only).
- Descriptor/PLC scrap wiring: `docs/clients/cpack.plc.yaml` (`***TRIG_CS` on outfeed tags), `docs/clients/cpack.descriptor.yaml`.
- Prior root-cause (reader duplication, fixed): `docs/clients/cpack-legacy-oracle-line-meters.md`.
- Counter-role model: `docs/clients/cpack-line-oee-lead-machine.md` §"Complete counter-role matrix".
- Live Q table: `equipment_runtime_shift`, ent 3, F3 `packiot_analytics`, 45-day window.
- Staging decoder flags observed: `COUNTER_ROLES_FROM_DB=true`, `PHASE9_LINE_AGG_ENABLED=true`, `COUNTERS_ONLY_OEE_ENABLED=true`; `packml_register.id_{infeed,outfeed,reject}counter` all NULL for ent 3.
