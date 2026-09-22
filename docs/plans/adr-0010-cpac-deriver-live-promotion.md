# ADR-0010 §10.4 — promote the CPAC count-silence deriver to LIVE for counters-only clients

**Status:** PLAN. Motivated by the Bispharma (ent5) demo-readiness review (2026-09-22):
counters-only clients have **no downtime events** and there is no non-synthetic way to
give them one today.

## Problem

`bi.downtimes` / the Downtimes menu + Pareto are **empty for Bispharma (ent5)** —
`silver.equipment_events` has 0 rows for ent5, ever. Root cause is structural, not a bug:

- **CPACK (ent3)** has 1,192 downtime events/day because its edge box emits **`MachSpeed`**
  — a speed stream — and the mirror fan-out mints running/stopped `equipment_events` from
  speed crossing thresholds.
- **Bispharma's box is pure counters** — no `MachSpeed`, no `StateCurrent` (confirmed: 0 in
  the `bispharmastaging-tee` stream and none in the box `reader.config.json`). It is
  `counters_only_oee=true`. There is **no speed/state stream to derive events from.**
- The **only** mechanism that can mint events for a counters-only client is
  **count-silence derivation** — and it already exists
  (`services/stream-engine/internal/events/cpac_deriver.go`, ADR-0010 §10.4) but runs
  **DARK**: it writes to a *shadow* table (`equipment_events_cpac_shadow`), scoped to CPACK
  only, for comparator validation. It mints nothing live for anyone.

So Bispharma's availability *number* is derived (line-lead sessionization in
`rollup/line_lead.go`), but there are no discrete downtime **event rows** for the UI.

## What the deriver already does (accurately)

`cpacTransitionsCTE` (25h window) sessionizes count activity:

- reads `silver.equipment_categorical_1min` where `gross_production_incr > 0` (productive minutes),
- a per-equipment gap `> COALESCE(NULLIF(stop_threshold_time,0), CPAC_STOP_THRESHOLD_DEFAULT_SEC=300)`
  closes a session,
- mints **status 6 (RUNNING)** at session start and **status 10 (STOPPED)** at
  `run_last + threshold` (once the grace has actually elapsed),
- scope: `status_type = 0 AND tp_equipment IN (1,3) AND id_enterprise = ANY($1)`,
- **idempotent** on `(id_equipment, ts_event)`, and **never clobbers an operator-touched row**
  (`humanTouchedPred` guards both the upsert and the delete).

It is wired at `cmd/oeecloud-worker/main.go:400` behind `CPAC_EVENT_DERIVATION_ENABLED=true`
with `Enterprises=CPAC_EVENT_ENTERPRISES` (`3`) and `TargetTable=CPAC_EVENT_TARGET_TABLE`
(default = the shadow table).

## The two-writer constraint (why this is per-enterprise, not a global flip)

`CPACConfig.TargetTable` is a **single global** target. Naively pointing it at live
`equipment_events` would make the deriver **double-write CPACK's speed-based live events**
(owned by the mirror fan-out) — the #456 two-writer double-count class.

The clean separation:

| Client | Has a live event source? | Deriver role |
|---|---|---|
| CPACK (ent3) | YES — speed → mirror fan-out | **stay SHADOW** (keep validating) |
| Bispharma (ent5) | **NO** — counters-only | **promote to LIVE** (sole writer, safe) |

The deriver can mint LIVE only for enterprises with **no competing event writer**.

## Design

Add a **second, live-targeted deriver instance** (or a `CPAC_EVENT_LIVE_ENTERPRISES` list
with a per-enterprise target) so the two roles coexist:

- **Instance A (unchanged):** `Enterprises=[3]`, `TargetTable=equipment_events_cpac_shadow`
  — CPACK, shadow, keeps feeding the comparator.
- **Instance B (new):** `Enterprises=[5]`, `TargetTable=equipment_events` — Bispharma, LIVE,
  the sole event writer for a counters-only client.

Minimal wiring: a second `RunCPAC` registration in `main.go` gated on a new
`CPAC_EVENT_LIVE_ENTERPRISES` env, target `equipment_events`. No change to the SQL — the
`humanTouchedPred` + idempotency already make live-minting safe.

## Preconditions to verify

1. **ent5 equipment is `status_type = 0`** — the scope filter requires it (Bispharma is
   counters-only, so almost certainly yes; verify `core.equipments` for ent5).
2. **Comparator gate passes for CPACK** — run `cpac_deriver_comparator.sql`: the shadow-derived
   transitions must match CPACK's speed-based live events within tolerance (precision/recall).
   This is the whole reason the deriver was built dark; ent5 has no speed ground-truth, so
   CPACK's agreement IS the accuracy proof we borrow.
3. **⚠️ Feed reliability (the coupling with the coverage gap).** Count-silence derivation is
   only correct on a **reliable** feed. Bispharma's box→staging co-tee is **lossy** (~40% of
   posts don't reach the ingest; see the 2026-09-22 coverage finding) — so a counter can go
   silent because of **network loss, not a real stop**, and the deriver would mint **false
   downtimes**. **A reliable ent5 feed is therefore a hard precondition** for accurate derived
   events. On the current lossy co-tee, expect false stops; validate downtime counts against
   the known-live lines before trusting them. (This is why Investigation 1 gates Investigation 2.)

## Rollout

1. Verify preconditions 1–3.
2. Land the Instance-B wiring + `CPAC_EVENT_LIVE_ENTERPRISES` config (default empty = inert).
3. Enable for ent5 on staging; verify `silver.equipment_events` ent5 populates with 6/10
   transitions, `bi.downtimes` + the Downtimes menu/Pareto render, and **no double-write**
   (each ent5 equipment has exactly one event writer).
4. Sanity-check derived stops against reality on the reliable lines (not the lossy/absent ones)
   — tune `stop_threshold_time` per line if the co-tee's cadence trips false stops.
5. Generalize: `CPAC_EVENT_LIVE_ENTERPRISES` becomes the list of counters-only clients with no
   speed/state source — the durable answer for the whole class, not just Bispharma.

## Risks

- **False stops on a lossy/cycling feed** (precondition 3) — the biggest one; fix the feed first.
- **Threshold tuning** — `CPAC_STOP_THRESHOLD_DEFAULT_SEC=300` may over/under-call stops per line.
- **Single-writer discipline** — never add a live enterprise that already has a speed/state
  event source (would double-write). Keep CPACK shadow.

## Related

- `services/stream-engine/internal/events/cpac_deriver.go` (the deriver), ADR-0010 §10.4.
- `feedback_bug_two_writer_line_double_count` — why the per-enterprise target split matters.
- Bispharma coverage-gap finding (2026-09-22) — the lossy co-tee that gates precondition 3.
- `rollup/line_lead.go` — the availability *number* already derives from the same count-silence
  sessionization; this plan lifts the same signal into discrete *events* for the UI.
