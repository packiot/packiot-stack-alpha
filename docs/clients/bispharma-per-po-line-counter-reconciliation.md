# Bispharma (ent5) — per-PO production: line-counter reconciliation

**Status:** FOLLOW-UP / onboarding task · **Date:** 2026-09-22 · needs client-box + cloud coordination.

## Goal
Make **per-production-order production** work for Bispharma so the Orders view shows POs
carrying real production (and per-PO OEE once the platform-wide denominator gap is closed).
Today ent5 has 1 stale PO (`net=0` since Sep 15) + 9 finished; the Orders view is empty.

## Root cause (verified, 2026-09-22)
PO attribution matches a PO's `id_equipment` to `equipment_values` rows. It **works** — CPACK's
tp=3 line-POs capture net (`po eq=47 net=28913`, the line has **129 direct rows/h**). But
**ent5 lines have 0 direct counter rows** — so ent5 line-POs capture `net=0`.

The **descriptor is already correct.** `docs/clients/bispharma.descriptor.yaml:85`:
```yaml
{topic: .../LINHAS/L01, id_equipment: 40001, tp_equipment: 3,
 line_roles: [{role: consumed, count_index: 168}, {role: processed, count_index: 169}]}
```
It binds the LINE to gross(168)/net(169) with **no S1INFEED member** — the line should own its
counters. The `line_roles` generator (`clientdescriptor/generate.go`, `line_roles_test.go`)
synthesizes `/LINHAS/L01/Admin/ProdConsumedCount/168/Unit → the line id_equipment`.

**But the live staging state DRIFTED from the descriptor:**
1. The **box `reader.config`** emits the gross as a *member-shaped* topic —
   `/SP/LINHAS/L01/S1INFEED/Admin/ProdConsumedCount/168/Unit` — not the line-shaped
   `/L01/Admin/…/168` the descriptor's `line_roles` expect.
2. The live **`packml_register`** routes `/L01/S1INFEED` → **member `2000225`**, and the staging
   **tenant-profile** (`docs/clients/tenant-profiles/bispharmastaging.yaml`) still carries the
   stale `/LINHAS/L01/S1INFEED: 168` member override.
3. So DW0 (gross) lands on the S1INFEED *member*, and the LINE (`2000224`) gets nothing.

Net: line-lead OEE still works (it reads gross from `gross_machine=2000225`), and downtimes work
(count-silence on the member), but **line-POs can't attribute** — the line has no direct data.

## The reconciliation (two layers)

### Layer 1 — CLOUD (a reviewed migration; implements the descriptor's intent for the box's shape)
Route the box's actual gross topic to the LINE and point the line's gross at itself. **PILOT ON L01
FIRST**, then generalize to the 14 Shape-A lines (L01 L03 L04 L05 L06 L07 L09 L11 L12 L13 L14 L16 L19 L20).
```sql
-- PILOT (L01). Rollback = swap the ids back.
BEGIN;
UPDATE packml_register SET id_equipment = 2000224, id_unit = 2000224
 WHERE packml_topic = 'BISPHARMASTAGING/SP/LINHAS/L01/S1INFEED';   -- gross → line
UPDATE core.equipments SET gross_machine = 2000224 WHERE id_equipment = 2000224;  -- line reads its own gross
COMMIT;
```
Also update the staging tenant-profile so a regen doesn't re-introduce the member override.

### Layer 2 — BOX (the durable native fix; removes the need for the cloud override)
Change the client box `reader.config` so the gross (DW0) is emitted **line-level**
(`/L01/Admin/ProdConsumedCount/168`), matching the descriptor's `line_roles` natively. Client-box
change (mi-0114); coordinate a window (the reader feeds the client's production pipeline).

## Interactions to VERIFY on the L01 pilot (this touches shipped systems)
- **line-lead OEE** — with `gross_machine=2000224`, L01's line OEE must still compute (the line now
  reads its own gross). Confirm `bi.oee_hourly` L01 stays non-zero.
- **Downtime deriver** (ADR-0010 live, #1384) — the S1INFEED member (2000225) goes silent → its
  stops move to the LINE (tp=3 is in scope). Arguably *better* (line-level downtimes) but it CHANGES
  the current member-level Pareto — verify the stops still land, on the line.
- **decoder packml cache** — the repoint takes effect after the decoder's reference cache refreshes
  (~1 min) or a decode restart; confirm the line starts getting rows.
- **No double-write** — the member must STOP getting 168 once the line takes it (single writer).

## Test (L01 pilot) — the acceptance gate
1. Apply Layer-1 pilot. Wait for cache refresh.
2. `select count(*) from silver.equipment_values where id_equipment=2000224 and ts_value>now()-interval '3 min';` → **> 0** (line gets data).
3. Create+start a PO on L01 via `POST /api/production-orders/{create,start}`; after ~10 min confirm
   `production_orders.net_production > 0` (attribution works). Then stop+delete the test PO.
4. line-lead OEE + downtimes intact (above). If all green → generalize to the 14 Shape-A lines.

## Scope notes
- This unlocks per-PO **gross production** (168). **Quality stays 100%** regardless — the PLCs don't
  populate scrap/net (DW4=0, DW20=0; see `bispharma-oee-mapping-fix.md` + the feed/quality finding).
- Per-PO **OEE%** is a *separate*, platform-wide gap (denominators unpopulated since Jan 2024 — even
  CPACK POs show `oee=0` with real net).
- Shapes B (L18) and C (L90) differ — do NOT blanket-apply; see `bispharma-oee-mapping-fix.md`.

## Related
- `bispharma-oee-mapping-fix.md` — the canonical role model (168=gross, 169=net=DW0−DW4, DW4=scrap).
- `bispharma-twin-convergence-runbook.md` — the (superseded) synthetic-twin fallback.
- A small **PO-action replayer** (create→start→wait→stop loop via edge-api) is the layer that makes
  POs *rotate* once this reconciliation lands — build it AFTER the L01 pilot proves attribution.
