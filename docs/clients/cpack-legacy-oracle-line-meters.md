# CPACK line metering — authoritative oracle record (legacy packiot40)

**Evidence record (SSoT) for the CPACK line infeed/outfeed count-index meters.**
The *seed* that provisions these values is `edge-deployment/cpack/cpack-register.sql`
(the `UPDATE packml_register SET id_infeedcounter/id_outfeedcounter …` block). This file
is the **evidence** those values are correct; `cpack-register.sql` is the **authority**.
The two MUST agree. `cpack.plc.yaml` is the human PLC reference and must not contradict either.

**Oracle:** legacy prod DB `packiot40` @ 18.220.223.110 (enterprise 1 = C-PACK), read-only.
**Why it's trustworthy:** CPACK's factory tees to BOTH the legacy stack AND our new stack
simultaneously, so legacy `equipment_values` is live (max ts = now). It is a **live
differential oracle**, not a historical snapshot.

**Method (differential, the proven one):** the oracle LINE (tp=3) carries a direct
own-stream count; the member machine whose full-window totalizer is *identical* to the
line's is the physical meter. `line gross == infeed member`, `line net == outfeed member`,
matched over 2.5k–4.3k rows/shift (byte-for-byte, not coincidence).

---

## CANONICAL line meters — current, all six oracle-byte-matched (last verified 2026-08-26)

`Parameter30700 = [id_infeedcounter, id_outfeedcounter]`. The values are **WIRE count-indices**
(`topicArray[7]` — the `.../<idx>/Unit` suffix the agent publishes), which is what Phase-9's
`line_aggregation.go` / `line_param30700_seed.go` match. They are **not** `id_equipment`.

| Line (F3 id) | infeed (gross) | outfeed (net) | wire meter | oracle byte-match | notes |
|--------------|----------------|---------------|------------|-------------------|-------|
| L3 (48)  | BREYER | TEXA | **76 / 80** | line gross==BREYER(76), net==TEXA(80) | wire idx == legacy id. Line gross is a faithful gap (see §L3). |
| L4 (49)  | BREYER | TEXA | **6 / 10**  | line 419k/468k == oracle | L4 uses **LOCAL** wire idx 6..10 (BREYER=6…TEXA=10), NOT legacy ids 88/84. net>gross conversion quirk (see §conversion). |
| L5 (47)  | BREYER | TEXA | **61 / 65** | line 803k/166k == oracle | wire idx == legacy id. |
| L6 (50)  | BREYER | TEXA | **91 / 92** | totalizer ratio 0.912 == oracle 0.884 | wire idx == legacy id. Corrected 94(RMH)→91(BREYER) 2026-08-24. net>gross windows = reseed settling. |
| L8 (51)  | DXL | **TCX** | **219 / 221** | oracle TEXA(222)≡TCX(221) byte-for-byte | outfeed=TCX(221) NOT TEXA(222): #59 repoint (TEXA reader reg DB1,DINT20 stale). |
| L10 (52) | DXL | **TCX** | **564 / 566** | oracle TEXA(567)≡TCX(566) byte-for-byte | outfeed=TCX(566) NOT TEXA(567): #59 repoint. |

**No meter-value change is warranted — all six are oracle-correct.** Verified live on F3
(`packiot_analytics`, ent-3) and mirrored identically on the SBXCPACK sandbox (ent-2000003).

⚠ **Seed-drift note:** `cpack-register.sql` shipped `L8=219/222` and `L10=564/567` (TEXA)
after the #59 live repoint had already moved F3 to `221`/`566` (TCX). The seed was corrected
to `221`/`566` on 2026-08-26 (fold of PR #916). A fresh re-provision now seeds the live values.

**Index/id collisions (why `COUNTER_ROLES_FROM_DB` MUST stay `false`):** several wire
count-indices equal a real `id_equipment` (L5 65→L4-RMH/61→L3-PTH; L6 91/92→BREYER2/PTH80S;
L3 76/80→L8/L10-TEXA). The ADR-0047 counterroles resolver reads these same columns but
interprets them as `id_equipment`, so it mis-binds a foreign machine's counter into the line
(the CPACK L5 net-phantom, #918). Phase-9 reads them correctly as count-indices. Keep
`COUNTER_ROLES_FROM_DB=false` while these columns hold count-indices.

---

## §L3 phantom — the #909 counter-role flip fabricated L3 line gross (2026-08-26)

**Symptom.** F3 L3 line (48) emitted steady gross (~21k over 09:00–13:00 UTC, ~44k/day, no
spikes) while the oracle L3 line (75) and *every* member were completely idle (gross=0/net=0,
240 heartbeats in the same window). Both stacks read the same PLCs, so a real L3 run would
show on the oracle too — it does not. **Phantom, definitively.**

**Root cause.** PR #909 ("correct 5 line-meter counter roles", 2026-08-25) relabelled the
L3 reader tag on **PLC L3 (10.135.16.127) DB1,DINT0**:

| register | legacy/oracle reader (:1881) | #909 flip (broke L3) |
|----------|------------------------------|----------------------|
| DB1,DINT0  | `L3/BREYER ProdProcessedCount/76` (net, TRIG_C=I) | `L3/BREYER ProdConsumedCount/76` (gross) |
| DB1,DINT28 | `L3/TEXA ProdConsumedCount/80` (gross, TRIG_C=O)  | `L3/TEXA ProdProcessedCount/80` (net) |

`76` is the L3 line INFEED (gross) meter. By relabelling DB1,DINT0 → `ProdConsumedCount/76`,
#909 routed that live-climbing register straight into the line gross → phantom. Timeline
confirms: F3 L3 line was net-tracking (matching the oracle) through Aug 25; the gross-only
phantom began exactly at the Aug-26 00:28 reader redeploy of the #909 flip. #909 was an
over-eager attempt to close L3's *known gross gap* (see §gaps) and produced a fabricated
gross instead of a real one. The same #909 commit also flipped **L4/TEXA, L8/DXL, L10/DXL** —
those three are oracle-verified correct and were **kept** (only the two L3 tags were reverted).

**Fix (reversible, 2026-08-26).** Reverted the two L3 tags to the legacy/oracle mapping in:
the live factory reader (`edge-cpack-nodered:/data/flows.json`, backed up to
`flows.json.bak-l3-*`, reader restarted, no spike on the other lines), the generator SSoT
(`cpack.descriptor.yaml` — BREYER `ProdProcessedCount/76 infeed_only`, TEXA
`ProdConsumedCount/80 outfeed_only`), the reader-flow seed (`cpack-reader-flow.json`), and
`cpack.plc.yaml`. This returns L3 to the pre-#909 state (line gross = known faithful gap,
no phantom) which matches the oracle. **Revert path:** re-apply #909's two L3 lines.

---

## §conversion — L4/L6 net>gross is FAITHFUL (do not "fix" into a phantom)

On the label/conversion lines the outfeed count legitimately exceeds the infeed count
(one infed sheet → many output labels/pieces), so **net > gross** is physically real and
**present in the oracle too**:

- **L4** oracle official `gross=33282 / net=38853 / scrap=−5571` (negative scrap = the
  conversion gain). Our F3 line byte-matches (419k/468k, ratio 1.119).
- **L6** shows net>gross in some early-shift/reseed windows; the long-run totalizer ratio is
  0.912 (net<gross), matching the oracle's 0.884.

The `equipment_runtime` CHECK clamps Quality to 1.0 when net≥gross. That clamp is an
**OEE-model limitation, not a count-index error** — do NOT swap the meter (e.g. L4 10/6) to
force net<gross; that is an unproven guess and both `6/10` (L4) and the current L6/L8/L10
meters are convention- and oracle-designation-consistent. How OEE should treat a conversion
line (units-per-count / multiplier, or a distinct quality definition) is a **per-client
product decision** and folds into the counters-only / per-client-OEE brief — not a meter fix.

---

## §gaps — known reader/data-quality defects (NOT meter problems; out of scope for this record)

All trace to the generated reader's per-machine Consumed/Processed register mapping, the
open reader-fix follow-up (needs factory register confirmation, #59 lineage):

- **L3 line gross** — the generated reader does not map BREYER's real *gross* register, so
  the line ProdConsumedCount(76) leaf never fires → line gross=0 (faithful gap). This is what
  #909 tried and failed to close (see §L3). Leave gross=0; do not synthesize it.
- **L5 members** — F3 L5-BREYER(53)/L5-PTH(55) show totalizer garbage (wrap/spike) that can
  poison the line gross; a member spike-guard defect, not a meter.
- **L8** — meter 219/221 config-correct but the line runs only when L8 runs (oracle L8 often
  idle at gross ~815).
- **Outfeed net inflation** — our outfeed machines historically decoded net≈gross (Quality
  ~1.0) where the oracle shows ~10% scrap; a reader ProdProcessedCount-source defect, tracked
  separately. Does not affect the count-index meters recorded above.

---

## Line multiplier (context)

`production_orders.multiplier` / `_runtime.multiplier` is per-PO (product units-per-count),
applied at the OEE/target grain (raw counts are 1:1). **CPACK currently = 1** (no scaling).
The new stack seeds only a `counter_multiplier` state (edge-transformer main.go), NOT the PO
multiplier — a gap for any tenant/PO running multiplier≠1.

---

## Change log (history preserved, contradictions removed)

- **2026-08-18** — first differential derivation on F1; seeder taught to prefer
  `[id_infeedcounter, id_outfeedcounter]`. *(Superseded designations from this pass —
  "L6 gross=RMH(94)", "net=max-index" — are corrected below; do not use them.)*
- **2026-08-24** — full re-reconciliation on F3 (post F1→F3 retirement). **L6 corrected
  94(RMH)→91(BREYER)** (a factory infeed change ~Aug 19; RMH gave impossible Q=1.25).
- **2026-08-26 (a)** — #59: **L8/L10 outfeed repointed TEXA→TCX** (219/221, 564/566); TEXA
  reader register DB1,DINT20 stale, oracle TEXA≡TCX. Seed corrected (drift; fold of #916).
- **2026-08-26 (b)** — #918: `COUNTER_ROLES_FROM_DB` disabled (Phase-9 sole mechanism);
  full re-verification byte-matched all six meters — no value changes warranted.
- **2026-08-26 (c)** — **L3 phantom fixed**: reverted the #909 L3/BREYER + L3/TEXA flip
  (see §L3). *(Earlier notes that called L4 "6/10 matches nothing → use 88/84" or L3 a
  "meter" problem are corrected: L4's wire idx IS 6..10, and L3's gross is a reader gap.)*

## Access note

Oracle read-only via `awslambda@packiot40` (creds in Secrets Manager `databaseCredentials`).
F3 via SSM on the staging box → `postgres@packiot_analytics` (10.10.10.89). No writes to legacy.
