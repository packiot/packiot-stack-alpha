# Decision brief — counters-only line availability & the "run = 0" policy

**Status:** OPEN — needs a product/OEE-config decision (not a mechanical fix).
**Feeds:** ADR-0047 (per-client configuration architecture / config-as-data).
**Owner to decide:** Product + CS (per-client OEE definition). Engineering implements once chosen.
**Author:** staging-hygiene sweep, 2026-08-26. No code changed by this brief.

---

## 1. What "counters-only availability" is

Some tenants (CPACK today; any Modbus/S7 count-only client) emit **only counters** — no
`Status/StateCurrent`, no `Status/MachSpeed`. There is no run/stop signal, so Availability
(the A in OEE = A·P·Q) cannot be read; it must be **inferred from counter activity**.

The engine already does this (`services/stream-engine/internal/rollup/availability.go`):
**idle-timeout gaps-and-islands sessionization** — each 1-minute bucket with
`gross_production_incr > 0` is a "productive minute"; consecutive productive minutes whose
inter-minute gap never exceeds an **idle timeout** form one running "session," credited
through `last-count + idle_timeout`. `running_time = Σ sessions`, `oee_a = running_time /
available_time`. It engages only for opted-in equipment and only when the bucket carried no
state events. Relevant knobs (all currently global env, default OFF):

| env | default | meaning |
|---|---|---|
| `COUNTERS_ONLY_AVAILABILITY_ENABLED` | `false` | turn the fallback on |
| `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS` | `""` | opt-in equipment id list |
| `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` | `300` | the flat-counts → "stopped" threshold |
| `COUNTERS_ONLY_LINE_LEAD_ENABLED` / `_ENTERPRISES` | `false` / `""` | derive a tp=3 line's runtime from its `lead_machine` counter stream |

## 2. The ambiguity counters alone cannot resolve

When the counter is **flat (Δ = 0)** for a stretch — up to and including a whole shift
(the "run = 0" case) — the counter stream **cannot tell us why**:

- the machine was **broken / micro-stopped** → this is real **unplanned downtime**, an
  Availability loss that OEE *should* penalise; **or**
- there was **no PO / no demand / it was unscheduled** → this time is **not a loss**, it
  should be **excluded** from the OEE denominator; **or**
- **planned** downtime (changeover, maintenance) → excluded from A by definition.

Distinguishing these needs a signal *other than the counter*: the **PO lifecycle**
(`production_orders` open/closed), the **shift calendar** (`shift_hours`), or an **operator
downtime justification**. Which of those exist, and how to weight them, is a **per-client
policy** — the same "OEE is not one formula" directive behind ADR-0047.

### Why this is live and non-academic
On CPACK ent-3 (read-only diag, 2026-08-12): **73 of 149 "running" shifts had
`running_time > 0` but `gross = 0`.** Simple-averaged with the producing shifts they dragged
line OEE from ~0.38 down toward ~0.20 and made Quality look like a broken constant 0.429
(it was really a 0/1 mixture; producing-only Q = 0.943). The `bi.oee_shift/_hourly` views
filter `running_time > 0` but **not** `gross > 0`, so zero-production "running" time slips
into the denominator inconsistently. **The number you show the customer depends entirely on
which policy below you pick** — so it must be a deliberate choice, not an accident of a
`WHERE` clause.

## 3. Two distinct knobs

**Q1 — idle-timeout threshold** (within-shift micro-idle). How long may counts stay flat
before the minute flips from "running-but-slow" to "stopped"? A slow line legitimately emits
one count every few minutes; a fast line flat for 90 s is down. Today: one global 300 s. This
should be **per-equipment/per-line config** derived from each line's expected cadence (e.g. a
multiple of the median inter-count interval). Low blast radius, uncontroversial — just needs
to move from global env → config-as-data.

**Q2 — the "run = 0" / zero-production policy** (the real decision). What does an extended
flat/zero counter period *mean* for Availability and for the OEE denominator?

## 4. Options for Q2 (with tradeoffs)

| # | Policy | run=0 counts as… | Needs | Pro | Con |
|---|--------|------------------|-------|-----|-----|
| **A** | **Productive-availability** (status quo of the raw sessionizer) | Availability **loss** — flat counts beyond idle-timeout ⇒ stopped ⇒ A↓ | counters only | simplest; no extra signal; conservative (never overstates OEE) | punishes *unscheduled/no-demand* idle as if it were a breakdown; tanks OEE on quiet shifts; the CPACK 0.20 artifact |
| **B** | **Exclude zero-production shifts** | **excluded** from the OEE denominator (treated as unscheduled) | a "productive shift" test (`gross > 0`) | matches what the dashboards half-do; stops idle shifts diluting the average | hides genuine all-shift breakdowns; a truly-down line simply "disappears" from OEE instead of scoring 0 |
| **C** | **Availability = N/A / NULL** when no counts + no other signal | neither loss nor excluded — surfaced as **undefined** | UI that renders N/A distinctly | honest ("we don't know"); no fabricated number | N/A is awkward to aggregate; pushes the ambiguity to the dashboard |
| **D** | **Schedule/PO-gated** (recommended) | run=0 **inside** an open-PO *and* scheduled-shift window ⇒ **loss**; run=0 with **no open PO / outside schedule** ⇒ **excluded** | `production_orders` + `shift_hours` (both already exist) | matches the real OEE definition (loss only during scheduled+committed time); reuses signals we already have; each tenant tunes what "scheduled" means | more moving parts; depends on PO/shift data being clean for that tenant; falls back to B where those signals are absent |

## 5. Recommendation

1. **Adopt D (schedule/PO-gated) as the default**, with a **graceful fallback to B** when a
   tenant has no reliable PO/shift signal on the line. Rationale: A is the textbook Availability
   definition — *loss only during scheduled, committed production time* — and CPACK already has
   `production_orders` + `shift_hours`. D is the only option that separates "broken during a run"
   from "quiet because there was nothing to make," which is exactly the CPACK 73-shift artifact.
2. **Make it a per-client config knob**, not a global constant — e.g.
   `availability_zero_production_policy ∈ {productive_loss, exclude_unscheduled, schedule_gated}`,
   set at onboarding and editable in CSAdmin (ADR-0047 Behavioral tier), effective-dated like the
   `downtime_reason` dimension.
3. **Promote the two existing global env knobs to config-as-data**:
   `COUNTERS_ONLY_IDLE_TIMEOUT_SECONDS` → per-equipment, and the `COUNTERS_ONLY_AVAILABILITY_*`
   opt-in lists → a per-client capability flag. They are the same "hard-coded but should be
   per-client" family as the `oee_q = net/gross` hard-coding.
4. **Never simple-average across shifts** — production- or time-weight — but note *whether
   zero-production shifts are in the denominator is exactly the policy above*, so fix the
   weighting **after** the policy is chosen.

## 6. Dependent clean-up (flagged, deliberately NOT done here)

Once Q2 is decided, the reporting layer must be made **consistent** with it — today it is not:

- `bi.oee_shift` / `bi.oee_hourly` filter `running_time > 0` but not `gross > 0`, so they
  silently implement a *half-B* policy that matches none of the options cleanly. Whichever
  policy is chosen, these views (and any Superset/PowerBI dataset on top) need the matching
  predicate. This is a deliberate, reviewed change gated on the decision — **not** a mechanical
  edit to slip in now.
- Forensic to run before finalising: confirm the 73 `gross=0 / running_time>0` CPACK shifts are
  genuine no-production (no open PO reached the line's tp=3 counter) vs a line↔member rollup gap.
  The policy choice is only valid on genuine zero-production; a rollup gap would be a *bug*, not a
  policy case.

## 7. Anchors (for whoever implements the decision)

- Sessionizer: `services/stream-engine/internal/rollup/availability.go`
- Idle-timeout / opt-in config: `services/stream-engine/internal/config/config.go` (~310–340, 486–490)
- Productive-minute heartbeat (`gross_production_incr > 0`): `internal/events/closer.go`,
  `internal/events/cpac_deriver.go`
- Line-lead derivation (CPACK): `internal/rollup/line_lead.go`; see
  `docs/clients/cpack-line-oee-lead-machine.md`
- Config-as-data design of record: `docs/adr/0047-per-client-configuration-architecture.md` +
  `docs/adr/reference/adr-0047-config-surface-spec.md`
- Hard-coded quality (same per-client family): `oee_q = net/gross` in the rollup/availability path
