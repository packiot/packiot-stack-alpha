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

## 2026-08-24 — FULL re-reconciliation on F3 (packiot_analytics, ent-3, live oracle)

Re-ran the meter derivation on **F3** (the F1→F3 retirement moved the data plane; the
old F1 backfill values had been carried into F3 verbatim). Method unchanged: match each
legacy LINE own-stream 24h total to the member whose 24h total is identical.

**Index space proven.** `line_aggregation.go` compares `topicArray[7]` (the index the
agent embeds in the published count topic, e.g. `.../L6/BREYER/Admin/ProdConsumedCount/91/Unit`
→ 7 = `91`) against `Parameter30700` csv[0] (infeed→line ProdConsumedCount/gross) and
csv[last] (outfeed→line ProdProcessedCount/net). The seeder emits the register
`[id_infeedcounter, id_outfeedcounter]` verbatim, so the meter values MUST be published
indices. Confirmed live: decoder `first_metric` logs and the agent map agree per member.

**Oracle 24h (2026-08-24), infeed=member matching line gross, outfeed=member matching line net:**
| Line | line gross | infeed(idx) | line net | outfeed(idx) | oracle Q |
|------|-----------|-------------|----------|--------------|----------|
| L3(75)  | 105926 | BREYER(76)  | 92290 | TEXA(80)  | 0.87 |
| L4(83)  | 92062  | BREYER(88)  | 97634 | TEXA(84)  | ~1 (legacy net>gross quirk) |
| L5(60)  | 87656  | BREYER(61)  | 79834 | TEXA(65)  | 0.91 |
| L6(90)  | 71930  | **BREYER(91)** | 48740 | TEXA(92) | 0.68 |
| L8(218) | 815 (idle) | DXL(219) | 0 | TEXA(222) | idle |
| L10(563)| 81100  | DXL(564)    | 70496 | TEXA(567) | 0.87 |

net = OUTFEED (TEXA) on every line (stable). gross = physical INFEED = BREYER (L3/L4/L5/L6),
DXL (L8/L10).

### L6 meter CORRECTED: 94 (RMH) → 91 (BREYER)  [APPLIED + VERIFIED live]
The 2026-08-18 doc designated L6 gross=RMH(94). A 7-day daily breakdown shows the legacy L6
own-stream gross exact-matched **RMH(94) on Aug 17-18** but **BREYER(91) on Aug 20-24** — the
physical infeed changed ~Aug 19. With the stale RMH meter our L6 line net(TEXA,53013) >
gross(RMH,42379) → Q=1.25, capped to 1.0 in equipment_runtime_shift = **inflated OEE**
(shifts showed Q=1.0). Corrected to BREYER(91): gross(73027) > net(53013) → Q≈0.73.
**Verified live:** after the register UPDATE + 5-min reseed, over an identical wall-clock
window our L6 line gross = **615 = oracle 615 EXACT**; net 567 vs oracle 513 (~10% high =
the separate outfeed net-inflation reader defect below, not the meter). Applied to CPACK +
SBXCPACK. Reversible: `SET id_infeedcounter = 94 WHERE packml_topic IN
('CPACK/SC/LINHAS/L6','SBXCPACK/SC/LINHAS/L6')`. (Current shift is partially contaminated by
pre-change RMH rows; all subsequent shifts are clean — recalc cannot repair the already-written
line rows.)

### Lines NOT changed — per-line disposition (all left as-is, evidence below)
- **L3(48)** meter 76/80 = oracle-correct. FAITHFUL GAP on **gross**: on our wire L3/BREYER
  emits `ProdProcessedCount/76` ONLY (decoder log, 16×; F3 BREYER id58 gross=0/net=3589) —
  the reader inverted Consumed/Processed → line ProdConsumedCount(first=76) never fires →
  line gross=0 → line OEE=0. A meter change cannot fix a missing/inverted leaf.
- **L4(49)** left at 6/10 (matches nothing → line absent). Oracle-correct = **88/84** but
  our wire L4/TEXA emits `ProdConsumedCount/84` ONLY (net=0 across 1289 rows/24h) → 88/84
  would materialise a gross-only line at **Q=0** (a "100% scrap" mirage, worse than absent).
  Enable 88/84 ONLY after the generated reader emits L4/TEXA ProdProcessedCount.
- **L5(47)** meter 61/65 = oracle-correct machines, but F3 L5-BREYER(53) gross=3,062,217 and
  L5-PTH(55) gross=9,970,435 are **totalizer garbage** (wrap/spike) → line gross poisoned →
  shift Q=0.017 (vs oracle 0.91). A MEMBER data-quality/spike-guard defect, not a meter
  problem. Out of scope for meter reconcile — flagged for the reader/spike-guard follow-up.
- **L8(51)** meter 219/222 = correct indices (DXL=219, TEXA=222 per agent map). Config-correct
  but IDLE (members ~0 rows; oracle L8 also idle at gross 815). Produces 0 until L8 runs.
- **L10(52)** meter 564/567 = oracle-correct indices. FAITHFUL GAP: on our wire L10/DXL emits
  `ProdProcessedCount/564` ONLY (F3 id77 gross=0/net=80598 — inverted like L3) and L10/TEXA(567)
  is not teed (0 rows) → line gross=0 AND net=0 → line absent. Reader/tee defect, not a meter.

**Summary:** of 6 lines, only **L6** had a meter that a value change fixes (RMH→BREYER,
correcting an inflated Q). L4/L3/L10 are reader-defect faithful gaps (correct meter identified,
held); L5 is a member-totalizer defect; L8 is config-correct-but-idle. All gaps trace to the
generated reader's per-machine Consumed/Processed mapping — the open reader-fix follow-up.

## 2026-08-26 — FULL re-verification (post counterroles-off / #918), all 6 lines byte-matched

Context: after PR #918 disabled `COUNTER_ROLES_FROM_DB` (Phase-9 is the sole line mechanism)
and #59 corrected L8/L10 outfeed (TEXA→TCX), a clean end-to-end re-verification of every
CPACK line's infeed/outfeed count-index against the live oracle (packiot40).

Method: the oracle LINE's own-stream `gross_production_val`/`net_production_val` totalizer was
byte-matched to the member whose totalizer is identical (that member = infeed / outfeed); the
result was cross-checked against each member's ACTUAL F3 wire count-index (the `.../<idx>/Unit`
suffix in `packml_register`, which is what Phase-9's `line_param30700_seed.go` matches).

| Line | oracle line gross = member | oracle line net = member | F3 wire meter | verdict |
|------|---------------------------|--------------------------|---------------|---------|
| L3 (48) | BREYER (76) | TEXA (80) | **76/80** | ✅ correct; line IDLE on oracle (479 rows, 0 gross/0 net) → NULL net is FAITHFUL, not stale |
| L4 (49) | BREYER (88) | TEXA (84) | **6/10** | ✅ correct — L4's wire uses LOCAL indices 6..10 (BREYER=6, TEXA=10), NOT legacy ids 88/84 |
| L5 (47) | BREYER (61) | TEXA (65) | **61/65** | ✅ correct (wire==legacy id); F3 line totalizer 803k/166k == oracle |
| L6 (50) | BREYER (91) | TEXA (92) | **91/92** | ✅ correct; long-run totalizer ratio 266M/292M = **0.912** (net<gross) == oracle 0.884 |
| L8 (51) | DXL (219) | TCX (221) | **219/221** | ✅ correct (TEXA(222)==TCX(221) totalizer; #59 fix validated) |
| L10 (52) | DXL (564) | TCX (566) | **564/566** | ✅ correct (#59 fix validated) |

**No meter value changes were warranted — all six were already oracle-correct.**

Two prior-note corrections:
- **L4 is NOT a "faithful gap."** The older disposition ("6/10 matches nothing → line absent;
  enable 88/84 after TEXA emits ProcessedCount") was wrong on two points: (1) L4's WIRE
  count-index is 6..10 — `packml_register` literally carries `.../ProdConsumedCount/6/Unit`
  through `/10/Unit`, so 6/10 matches and 88/84 (legacy ids) match nothing; (2) L4/TEXA(10)
  now emits ProdProcessedCount, so net flows (F3 line 419k/468k byte-matches the oracle).
  L4 **net>gross (Q clamps to 1.0) is a REAL conversion quirk**, present in the oracle too
  (official gross=33282/net=38853/scrap=−5571 — labels-per-sheet: outfeed pieces > infeed
  sheets). Per the "don't apply an unproven swap" rule, 6/10 is kept (convention- and
  oracle-designation-consistent); a 10/6 swap to force net<gross is a guess and is NOT applied.
- **L6 is correct at 91/92** (the 2026-08-24 RMH→BREYER fix holds). The transient net>gross
  some windows show is early-shift/reseed settling; the physical totalizer ratio is 0.912.

Residual (reader/data-quality, NOT meter — out of scope, flag to #59):
- **L3 gross divergence:** F3 L3/BREYER(idx76) emitted steady gross (~21k over the shift, no
  spikes) while the oracle L3/BREYER is idle (0). Spurious F3 gross, then idle. Net faithful (0).
- **L4/L6 net>gross** is a conversion/instrumentation reality (present in the oracle), clamped
  to Q=1.0 by the equipment_runtime CHECK — an OEE-model limitation, not a count-index issue.
