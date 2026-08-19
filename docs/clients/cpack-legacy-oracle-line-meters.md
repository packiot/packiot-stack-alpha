# CPACK line metering — authoritative oracle (legacy packiot40)

**Date:** 2026-08-18
**Oracle:** legacy prod DB `packiot40` @ 18.220.223.110 (enterprise 1 = C-PACK), read-only.
**Why it's trustworthy:** CPACK's factory tees to BOTH the legacy stack AND our new
stack simultaneously — legacy `equipment_values` is live (max ts = now). So this is a
**live differential oracle**, not a historical snapshot.

## How the meters were derived (differential method)

The legacy line (tp=3) carries a **direct own-stream count** (`C-PACK/SC/LINHAS/Lx/Admin/
ProdConsumedCount|ProdProcessedCount`) — the stream mirror-worker-go used to mirror and
that our new path lost (new wire = machine-level counts only). Matching each legacy LINE
total to the member machine whose total is **exactly equal** (over a full shift, 2.5k–4.3k
rows — not coincidence) reveals which machine physically meters the line:

| Line | id | legacy gross | = gross meter | legacy net | = net meter | Q |
|------|----|--------------|---------------|------------|-------------|---|
| L3 | 75 | 102735 | **BREYER (76)** | 97732 | **TEXA (80)** | 0.95 |
| L4 | 83 | 116025 | **BREYER (88)** | 131490 | **TEXA (84)** | 1.13* |
| L5 | 60 | 1 (idle) | **BREYER (61)** | 88693 | **TEXA (65)** | degen |
| L6 | 90 | 130447 | **RMH (94)** | 116504 | **TEXA (92)** | 0.89 |
| L8 | 218 | 117928 | **DXL (219)** | 107376 | **TEXA (222)** | 0.91 |
| L10 | 563 | 98365 | **DXL (564)** | 92770 | **TEXA (567)** | 0.94 |

\* L4 net>gross in the legacy too — a legacy data quirk, not ours.

**Rule that falls out:**
- **net meter = TEXA (the outfeed) on every line.** Never the max-count-index.
- **gross meter = the physical infeed**, which varies: BREYER (L3/L4/L5), **RMH (L6)**, DXL (L8/L10).
- Legacy machine `id_equipment` == the PLC count-index (L6: BREYER=91, TEXA=92, POLYTYPE=93,
  RMH=94, PTH=95). Confirmed matching our wire for L6; verify per line for the others
  (our staging count-index convention diverges on some lines — e.g. F1 L4 = 6..9).

## Divergences vs our new stack (Phase-9 ascending-index)

Our seeder builds `Parameter30700` as the ascending count-index CSV and Phase-9 uses
`csv[0]`=gross, `csv[last]`=net. That is **semantically wrong**:
- **Net**: ascending picks the max-index machine; the oracle says net is always **TEXA**.
  TEXA is not the max index on any line → net meter wrong on ALL lines.
- **Gross (L6)**: ascending picks BREYER(91); oracle says **RMH(94)**. BREYER gross
  (138218) ≠ RMH gross (130447) → ~6% gross error, wrong Quality.
- My live F1 L6 backfill (91,92,93,94,95) therefore meters BREYER/PTH; the **correct**
  Parameter30700 for L6 is effectively `94,…,92` (gross=RMH first, net=TEXA last).

**Correct per-line `Parameter30700` (gross-first, net-last):**
- L3: `76,80` · L4: `88,84` · L5: `61,65` · L6: `94,92` · L8: `219,222` · L10: `564,567`
  (map to our wire's actual count-indices before applying).

## The line multiplier

`production_orders.multiplier` / `production_orders_runtime.multiplier` — **per-PO**
(product-specific units-per-count), applied at the OEE/target grain (raw counts are 1:1:
legacy line gross == meter-machine gross to the unit). **CPACK currently = 1** (12869 rows
=1, rest NULL) → no scaling today. BUT: new stack has only a `counter_multiplier` state
seed in edge-transformer (main.go:823), **not** the PO multiplier — a gap for any tenant/PO
that runs multiplier≠1.

## Preview: an OUTPUT-phase divergence (deeper, not config)

Legacy L6-TEXA(92) net = 116504 (net<gross, real quality loss). Our F3 L6-TEXA net =
131485 (≈gross, ~no loss). Machine-level net/Quality is computed differently — likely
ProdDefectiveCount handling in decode. Flag for the output-diff phase.

## APPLIED (2026-08-18) — meter fix deployed + validated
- Seeder (`line_param30700_seed.go`) now PREFERS `id_infeedcounter`/`id_outfeedcounter`
  on the LINE register row → `Parameter30700 = [infeed, outfeed]` (explicit, unambiguous);
  falls back to the ascending member-index CSV for lines without meters. Compiles; deployed
  to staging edge-transformer (image 6e923fb).
- F1 backfilled the 6 CPACK line rows with oracle meters (our wire indices): L3=76/80,
  L4=6/10, L5=61/65, **L6=94/92**, L8=219/222, L10=564/567. Old L6 ascending /Unit rows removed.
- `PHASE9_LINE_AGG_ENABLED: "true"` added to the box compose.staging.yml (was a live-only
  override lost on recreate) — partial codify of task #8.
- **VALIDATED live:** after redeploy, our L6 line gross now tracks RMH(92=92) and net tracks
  TEXA(89), matching the oracle's designation (was BREYER pre-fix). Meter divergence CLOSED.

## OUTPUT-PHASE FINDING (open) — new stack under-reports quality loss
Full-day, both stacks fully running, same PLC:
| machine | legacy gross/net | our gross/net | legacy loss | our loss |
|---------|------------------|---------------|-------------|----------|
| RMH(94) | 130447 / 116383  | 132516/131502 | ~10.8%      | ~0.8%    |
| TEXA(92)| 130152 / 116504  | 132392/131485 | ~10.5%      | ~0.7%    |
| BREYER(91)| 138218/138218  | 140593/–      | 0 (infeed)  | 0        |
Our OUTFEED machines show net≈gross → Quality inflated ≈1.0; legacy shows the real ~10%
scrap. Not a literal net:=gross copy (907 diff exists), so processed IS decoded separately
— but reads a value ≈consumed. Since the two stacks use DIFFERENT edge readers (legacy
factory reader vs our ADR-0045-generated reader @10.135.1.173, same PLC), root cause is
most likely the generated reader mapping ProdProcessedCount to a register that tracks
≈consumed for the outfeed machines. PINNING needs the legacy edge reader's tag map (factory)
to diff against our generated reader's TEXA/RMH ProcessedCount source. Alt cause to rule out:
edge-transformer decode flattening processed→consumed (check Calc consumed/processed split).

## ROOT CAUSE PINNED (2026-08-18) — reader duplicates consumed→processed
The Quality inflation is a READER defect, cleared layer by layer:
- **Decode faithful**: applyTrigCorrections (counter_math.go) only forces net=gross under
  ***TRIG_C=O / C=I. The live L6 tags carry NO TRIG suffix → no mirror applied. The TRIG
  port itself is correct (matches legacy: L3 TEXA legitimately net=gross via TRIG_C=O, and
  the oracle agrees — L3 TEXA 97732/97732).
- **Agent faithful**: cpack-agent.yaml maps /L6/TEXA/ProdConsumedCount/92 AND
  /L6/TEXA/ProdProcessedCount/92 as two distinct double tags — no collapse/derive.
- **Reader is the culprit**: F3 L6-TEXA(69) has gross == net EXACTLY every row (diff=0),
  while legacy TEXA(92) is 130152/116504. The reader @10.135.1.173 (dumb producer; register→
  topic mapping generated from the descriptor plc: block) emits ProdProcessedCount = the
  ProdConsumedCount register value for outfeed machines → zero scrap → Quality=1.0.
Systematic across outfeed machines (RMH/TEXA/PTH). INFEED machines are unaffected (their
net==gross is physically correct — no scrap at infeed).

**Consequence — compounds with the meter fix**: Part-1 correctly makes line net = TEXA net,
but TEXA net is itself = gross (duplicated), so line Quality still ≈1.0 (should be ~0.89).
Both fixes are needed for correct Quality.

**FIX (needs factory data, report-only)**: the descriptor plc: block must map each outfeed
machine's ProdProcessedCount to its OWN PLC register (distinct from consumed). The real
register addresses live in the legacy factory edge reader's tag map (NOT the cloud
oee_cloud_node_red hosts — those are processors; the reader is factory-side) or PLC docs.
Until then our new wire physically lacks the real processed/scrap for outfeed machines.
Alt: source line net from the line's own-stream ProdProcessedCount if the tee can carry it.

## Access note
Oracle read via the `packiotdb` DBeaver connection (user `epodesta`), read-only SELECTs
from this workstation (packiot40 reachable). No writes to legacy.
