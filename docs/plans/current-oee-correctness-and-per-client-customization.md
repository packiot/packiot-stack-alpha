# Current-stack OEE correctness fixes + per-client OEE customization

**Status:** PLAN · **Date:** 2026-09-23 · Target: the current medallion stack (`packiot_analytics`), NOT legacy.

Motivated by a hardproofed CPACK current (ent3) vs legacy (`packiot40` ent1, "C-PACK") comparison,
3-month window. Legacy is complete but has its own bugs (unclamped net `net≫gross`, OEE>1) — we do
**not** fix legacy. We target current, and we design the fixes so per-client OEE differences are
**configurable** rather than hardcoded.

---

## 1. What the comparison proved (the motivation)

| Metric | Verdict | Evidence |
|---|---|---|
| **PO runtime rows** | current WAS wrong → **FIXED** | 651/1120 POs (58%) had `ts_start` but no runtime row; legacy had all; raw intact; 0 DLQ. Root: `OrderStarted` skipped `openRuntimeWindow` when the *start payload* equipment didn't resolve. Fixed by **PR #1389** + backfill (`t-cpack-backfill-po-runtime-windows`) + legacy-copy for cut-raw; historian is a live replica so it auto-synced. |
| **PO count** | current wrong (incomplete) | Older-month POs missing entirely — the *create* handler `ErrSkip`s the whole PO when the payload equipment doesn't resolve. → **Workstream 2**. |
| **Per-PO gross/net (clean data)** | both = RAW | PO order 897119: current `75405/64096`, legacy `74748/63599`, raw `75405/64096` — exact. |
| **Gross on anomalous lines** | **current wrong** | eq47 (L5) has spike increments (108951/104234 in one minute on 09-15) and PO 896206 shows `gross=14M` vs raw eq47 30d total `1.98M` vs legacy `310K` — frozen counter-anomaly garbage, no guard. → **Workstream 1**. |
| **Net / quality** | **current CORRECT** | current avg quality 0.87 ≈ raw 0.85; legacy over-counts (35/507 POs `net>gross`, worst ×24,635). |
| **OEE bounds** | **current CORRECT** | current clamps [0,1]; legacy allows OEE>1 (avg 1.05). |

**Takeaway:** current's *computation* is sound (net/quality/OEE-bounds match raw and beat legacy). Its
defects were **completeness** (fixed) and a **missing counter-anomaly guard on gross** (open).

---

## 2. Workstream 1 — counter-anomaly gross guard (per-equipment, client-configurable)

**Problem.** A physical counter that resets/wraps/spikes yields an impossible `gross_production_incr`
(eq47's 108951/min; PO 25489's −3.5e21; PO 896206's frozen 14M). The only existing guard —
`deltaSanityCap` in `services/mirror-worker-go/internal/reconcile/value_sync.go` (added after the
2026-07-04 ±1e38 "oscillator incident") — is a **single global cap** set high enough to allow real
deltas, so it catches ±1e38 but not the eq47 class.

**Fix.** A **per-equipment** plausibility bound at the increment layer (where `gross_production_incr`
is derived from the counter delta, in `mirror-worker-go`):

```
max_plausible_incr = ideal_production_speed × interval_minutes × MARGIN
```

Increments exceeding it are **clamped to the bound and flagged** (a `data_quality_event`, mirroring the
existing DQ machinery) rather than silently dropped or trusted. Also guard the **monotonic-counter
reset** case (`current < previous` ⇒ treat as a reset: increment = current, not a huge/negative delta).

**Why per-equipment + configurable (the client point).** `ideal_production_speed` and `MARGIN` differ
by client and by machine (a canning line vs a pharma blister line run at wildly different rates). The
bound must read the equipment's own speed, and `MARGIN` (and whether the behavior is clamp / reject /
flag-only) must be a **client-configurable policy** (see Workstream 3), not a constant.

**Hardproof plan.** Re-run the eq47/PO-896206 windows through the guarded path in a repro; assert the
clamped increment matches legacy (310K) and a DQ event is emitted; assert no regression on clean
equipment (DUBUIT2, which already matched exactly).

---

## 3. Workstream 2 — create-action `ErrSkip` drops whole POs (the count gap)

**Problem.** In `services/analytics-sync/internal/replicate/handlers.go`, the create/create-and-start
handlers do `eq, ok := r.ResolveEquipment(p.IDEquipment); if !ok { return ErrSkip }` — a legacy
equipment that doesn't resolve **silently drops the entire PO** (never created in current). This is the
older-month PO-count gap (legacy 1569 vs current 1084 over 3mo; Jul 565→237).

**Fix (two parts).**
1. **Make it visible + recoverable:** replace the silent `ErrSkip` with a DLQ (`ops.mirror_replay_dlq`)
   so unresolved-equipment creates are retried once the mapping exists — same pattern the runtime path
   already uses. Silent drops must never be the failure mode for missing data.
2. **Close the mapping gap:** enumerate the legacy CPACK equipment ids that fail `ResolveEquipment` and
   backfill the equipment mapping (the resolver's legacy→current table). Then drain the DLQ to create
   the missing POs; the Workstream-1 backfill then attributes them.

**Hardproof plan.** After the mapping backfill + DLQ drain, current 3mo PO count converges to legacy's
(1084 → ~1569); spot-check recovered POs against legacy.

---

## 4. Workstream 3 — per-client OEE computation customization (ADR-0058 extension)

**The requirement (client insight).** Different clients compute OEE differently — counter roles,
thresholds, availability derivation, quality basis, ideal-speed source, and now the anomaly-guard
policy from Workstream 1. Today these are a mix of per-equipment columns and hardcoded stream-engine
logic. They should be a **first-class, editable per-client OEE profile.**

**Configurable surface (candidate):**
| Knob | Today | Proposed |
|---|---|---|
| Counter roles (gross/net/scrap → count_index) | descriptor `line_roles` / `gross_machine` etc. | keep, surface in the profile |
| Availability derivation | state-based vs count-silence (env `COUNTERS_ONLY_*`, hardcoded enterprise lists) | per-client `availability_mode` |
| Stop / min-speed thresholds | `equipments.stop_threshold_time`, perf-threshold cols | per-client defaults + overrides |
| Ideal-speed source | `lead_machine.production_speed` (line-lead) | per-client `ideal_source` |
| Quality basis | `net/gross` | per-client (e.g. good/total, or scrap-derived) |
| **Anomaly-guard policy** | none (global cap) | per-client `max_incr_margin` + `on_anomaly = clamp|reject|flag` |
| OEE clamp | hardcoded [0,1] | keep (correct) — but make the *reconciliation* rules configurable |

**Architecture.** Extend **ADR-0058** (the descriptor / derive-rule / `expr-lang` framework already
built: `internal/agent/expreval`, `clientdescriptor`, tenant-profiles) with an **OEE profile** object
per client — declarative, versioned, validated, resolved at generate-time and read by the rollup
engine. The **customize** SPA (`customize.staging`, already deployed) gains an "OEE computation" editor
(like its derive-rule editor) so Customer Success edits a client's OEE policy without a code change.
The stream-engine rollup (`line_lead.go`, `compute.go`, `grains.go`) reads the resolved profile instead
of env lists + hardcoded formulas.

**Key architectural finding (the delivery seam).** The descriptor framework (persisted in the
`client_descriptors` JSONB row, served by `edge-api`) and the OEE knobs (stream-engine + decoder env
vars) live in **separate services with no shared profile object** — neither Go service reads
`client_descriptors` for OEE math today. WS3's spine is therefore a **config-as-data delivery path**:
each consuming service reads its subset of `descriptor->'oee_profile'` and overlays it on the env
default, so an absent profile is byte-identical (parity). This is the exact seam `countersrate.Watcher`
already established for the rated-speed map — WS3 reuses that shape.

### Phase 1 — DONE (this branch: `feat/ws3-per-client-oee-profile`)

The plan's sequencing note said to make WS1's guard the first consumer of a per-client knob to prove
the config path end-to-end before the full editor lands. That is now built:

- **Schema** — `descriptor.oee_profile` (TS `OeeProfile` in `customize/src/api/onboarding.ts`): the full
  knob set (`spike_margin`, `on_anomaly`, `availability_mode`, `ideal_source`, `quality_basis`,
  `stop_threshold_sec`, `version`), every field optional (unset = platform default). Rides the existing
  `client_descriptors` JSONB row — `edge-api`'s upsert DTO types `descriptor` as `Record<string,any>`
  (`@IsObject`, not a nested validated class), so `whitelist:true` stores it verbatim (persistence
  confirmed, no edge-api change).
- **Delivery (decoder)** — new `services/sparkplug-decoder/internal/oeeprofile` package: a `Watcher`
  mirroring `countersrate` that reloads a unit-topic→`spike_margin` map from
  `client_descriptors.descriptor->'oee_profile'` every `OEE_PROFILE_REFRESH_SECONDS` (gated by
  `OEE_PROFILE_FROM_DB`, default OFF, fail-open). The WS1 `CounterSpikeMargin` moved from `calc.Config`
  onto the per-message `calc.Message`; `main.go` resolves it per message = the topic's profile margin
  if authored, else the `CALC_COUNTER_SPIKE_MARGIN` env default. Absent profile ⇒ WS1's env behavior
  byte-for-byte. Table-tested (deriveUnitTopic↔ParseTopic key-parity on the eq47/L5 topics).
- **Editor (customize SPA)** — new "OEE Computation" page (`customize/src/pages/oee-profile.tsx`, nav +
  route wired): load descriptor → edit the profile → validated Save via the existing
  `upsertDescriptor`. `spike_margin` is badged **Live** (wired to the decoder); the rollup knobs are
  badged **Phase 2** (authored now, consumed as migrated). A cleared profile omits `oee_profile`
  entirely (back to defaults).

### Phase 2 — remaining (each ships with its own before/after hardproof)

Migrate the stream-engine rollup knobs off their env lists to read `descriptor->'oee_profile'`:
`availability_mode` (COUNTERS_ONLY_AVAILABILITY_* / line-lead), `ideal_source` (the hour/shift COALESCE
chain), `quality_basis`, `stop_threshold_sec` (events layer), and `on_anomaly` beyond `clamp`. Needs the
same `client_descriptors` read-path added to `stream-engine` (which today reads only env +
`equipments`/`packml_register`).

---

## 5. Sequencing

1. **WS1 (guard)** — highest correctness value; ship with a per-equipment bound + a client-default
   `max_incr_margin` field (seeds WS3). Retro-clean the existing eq47/PO-896206 class via a DQ pass.
2. **WS2 (ErrSkip → DLQ + mapping backfill)** — recovers the missing POs so counts match legacy.
3. **WS3 (OEE profile + customize editor)** — the durable home for per-client OEE differences; migrate
   the WS1 knob + the `COUNTERS_ONLY_*` env lists + thresholds into it.

Each workstream ships with the same before/after legacy-vs-current hardproof used to find these issues.
