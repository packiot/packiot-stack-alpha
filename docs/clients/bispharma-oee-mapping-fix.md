# Bispharma — OEE role-mapping fix (descriptor draft, semantics-gated)

**Status:** DRAFT / ready-to-review · **Date:** 2026-07-27 · **Task:** #54 ·
**Depends on:** `bispharma.descriptor.yaml` (branch `feat/task13-bispharma-descriptor-fill`),
[`bispharma-bisnago-canonical-model.md`](bispharma-bisnago-canonical-model.md)

> **What this fixes.** The staging validation produced `oee=0.2351` but **Performance-only**
> (`oee_a=0`, `oee_q=0`). Root cause is *not* a Calc bug — it is a **descriptor role gap**:
> the tp=3 line rows carry **no `count_index`**, so the line receives no counter feed, and the
> gross/net counters are mapped as generic tp=1 members. This draft re-roles the counters so
> line OEE computes **without** the deferred Phase-9 member→line aggregation
> (`calc.go:203`). **Every value marked `⟵CLIENT` is gated — do not cut over until confirmed.**

---

## 1. Ground truth (from `bispharma.json`, 16 `counters LXX` function nodes)

Three distinct line shapes exist in the flow. Do not assume one mapping fits all.

### Shape A — standard line (14 of 16: L01 L03 L04 L05 L06 L07 L09 L11 L12 L13 L14 L16 L19 L20)

Each line's `counters` node assigns a contiguous 6-id block. Using L01 (block 164–169):

| Flow counter | S7 word | Flow meaning (from code + comments) | OEE role |
|---|---|---|---|
| 168 | `DW0` | `counter168 = DW0` — first sensor, line infeed | **gross** → line `ProdProcessedCount` |
| 169 | `DW0-DW4` | `counter169 = DW0-DW4 // last sensor is the only one for scrap` | **net/good** → line good count |
| (DW4) | `DW4` | scrap sensor (raw word, available on tee; flow emits only `DW0-DW4`) | **defective** = gross − net |
| 164 | `DW8` | station S3 | member (tp=1) |
| 165 | `DW12` | station S4 | member (tp=1) |
| 166 | `DW16` | station S5 | member (tp=1) |
| 167 | `DW20` | station S6 output | member (tp=1) |

**Quality = net / gross = 169 / 168.** **Performance = net vs rated speed** (`⟵CLIENT`).

### Shape B — L18 (reconfigured, 8 machine counters 543–550, no gross/net split)

Flow node labels the machines: `DW0=I1 Tampadeira`, `DW8=I3 Prensa`, `DW12=I4 Torno`,
`DW16=I5 Acumulador`, `DW20=I6 Impressao`; `DW4/DW24/DW28 = "livre"` (spare, unwired →
NOT registered). **No infeed/scrap arithmetic** → no automatic gross/net. `⟵CLIENT`: which
machine is the line's good-output counter (and, if wanted, which is infeed) — until then L18
is **members-only, no line Quality**.

### Shape C — L90 (2 counters 684/685)

`counter684 = DW0 // sensor entrada da linha` (entry = gross);
`counter685 = DW1 // sensor saída da linha` (exit = good/net). **Quality = 685 / 684.**
No members. Note `DW1` (not `DW4`) — a different scrap convention; keep separate.

---

## 2. The mapping change (Shape A, per line)

**Before** (current descriptor — line has no feed; gross/net are members):
```yaml
- {topic: BISPHARMA/SP/LINHAS/L01, id_equipment: 40001, tp_equipment: 3}   # NO count_index → 0 rows
  ...
- {topic: .../L01/S1_INFEED, id_equipment: 40105, tp_equipment: 1, count_index: {value: 168 ...}}  # DW0  gross-as-member
- {topic: .../L01/SCRAP,     id_equipment: 40106, tp_equipment: 1, count_index: {value: 169 ...}}  # DW0-DW4 net-as-member
```

**After** (line carries the OEE roles directly — no Phase-9 needed):
```yaml
- topic: BISPHARMA/SP/LINHAS/L01
  id_equipment: 40001
  tp_equipment: 3
  status_type: 5                      # counters-only: NOT status_type=4 (EventMint overflow guard)
  production_speed: 0                 # ⟵CLIENT rated units/min — REQUIRED for Performance
  counters_only: true                 # opt into #591 / #600 counters-only OEE + availability
  line_roles:                         # NEW: bind the line's OEE leaves to flow counters
    ProdProcessedCount: {count_index: 168}        # DW0  gross infeed  (CONFIRMED-from-flow)
    ProdGoodCount:       {count_index: 169}        # DW0-DW4 net good   (CONFIRMED-from-flow)
    # ProdDefectiveCount is DERIVED = Processed - Good = DW4
  # DW8/DW12/DW16/DW20 stay as tp=1 members for drill-down (unchanged), OR drop if line-only
```

Quality then computes at the line as `Good/Processed`; Availability via the counters-only
activity fallback (#600/#607, already live for CPACK L6 — extend the enterprise gate to
bispharma); Performance from `production_speed`.

> **Why re-role instead of Phase-9 aggregate?** Phase-9 member→line rollup is *unimplemented*
> in the Go transformer (`calc.go:203` "deferred"). The line already owns its own DW0/DW4
> totalizers in the PLC, so the line does **not** need to sum its members — it reads its own
> gross/net. This makes line OEE ship now and leaves Phase-9 as a separate, optional item.

---

## 2b. Provisional rated speed — self-calibrating from observed throughput (unblocks B1)

tsp12 has **no** rated speed for bispharma (greenfield shell — 0 equipment rows, 0
`equipment_values`; nothing to read or infer from history), and the flow is counters-only
(no `MachSpeed`, no param 30701). Rather than block go-live on the client, **infer a
provisional ideal speed from the machine's own best demonstrated throughput** during the bake.

**Where it plugs in (no Calc change).** The rollup (`hour.go`/`shift.go`) already resolves
`ideal_speed` via a COALESCE fallback chain ending in `equipments.production_speed`:
```
COALESCE(equipment_values.ideal_production_speed,   -- param 30701 (absent here)
         locf'd ideal_production_speed,             -- (absent here)
         equipments.production_speed)               -- ← provisional job writes HERE
```
A periodic job fills that last slot; the existing chain (and the #622 sanity-clamp, which
also reads `production_speed`) picks it up automatically.

**Estimator (flag-gated oeecloud-worker task, default OFF):**
- Per tp=3 line, compute per-minute **good-count** rate over a trailing window (bake ≈ 24–72 h).
- Ideal := **p95** of those rates (NOT `max` — p95 sheds counter-reset / double-count glitches;
  reuse the #622 clamp + Node-RED reset-guard so resets don't inflate).
- **Guardrails:** require ≥N non-idle minutes (e.g. 240) before writing, else leave NULL
  (Performance stays null, never garbage); floor out near-zero p95; **only-fill-NULL /
  only-if-provisional** — never clobber a client-confirmed speed; idempotent UPSERT.
- **Mark provisional** (confidence column / `speed_source='inferred'`) so the client value
  overrides cleanly and dashboards can flag "self-calibrated."

**⚠️ Semantic caveat (tell the client).** Inferred ideal = *best demonstrated* rate, so
Performance is measured against the machine's own best, not an engineering nameplate. OEE will
read **higher** than a nameplate-based OEE, and will **drop** when the real nameplate (≥
demonstrated) is loaded. This is honest and standard ("demonstrated capacity"), but set the
expectation up front.

**Result:** B1 downgrades from a **hard go-live blocker** to a **refinement** — prod builds,
bakes, and shows a real (self-calibrated) OEE while the client gathers nameplate speeds.

## 3. Blockers to FULL OEE (what gates a real cutover)

| # | Gap | Nature | Resolution |
|---|---|---|---|
| B1 | **Rated speed per line** (units/min) | ~~hard~~ → **soft** (see §2b) | provisional p95-throughput inference now; `⟵CLIENT` nameplate refines later |
| B2 | DW0 = infeed semantics (Quality denominator) | confirm | `⟵CLIENT` — is DW0 raw-in (yield) or first-machine-out? |
| B3 | L18 infeed/output machine | mapping | `⟵CLIENT` — else L18 = members-only |
| B4 | L90 entry/exit = gross/net | confirm | `⟵CLIENT` — likely yes |
| B5 | Line-level only vs. member-level OEE | scope | `⟵CLIENT/USER` — onboard 16 lines, or 16 + 91 members |
| B6 | Availability enterprise gate | config (not client) | add bispharma ent to `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS` / rollup gate |
| B7 | Cold-start baseline | config (not client) | start capture near 0, or first-delta glitch-guard reject |

**B1 is the critical path.** Everything else refines an already-computing OEE; without rated
speeds there is no Performance dimension at all.

---

## 4. Apply plan (once B1–B4 answered)

1. Patch `bispharma.descriptor.yaml` line rows with `line_roles` + `production_speed` (§2).
2. `onboard-gen` → regenerate profile + register SQL + agent yaml + tee snippet.
3. Clean-from-zero staging run (drop ent-5 rows, re-seed, restart sim near 0) → verify
   `equipment_runtime_shift` has `oee_a>0`, `oee_q>0`, `oee_p>0` on a tp=3 line row.
4. Parity gate (Mode-A: F3-from-agent vs the flow's own `increment`), then per-tenant cutover.
