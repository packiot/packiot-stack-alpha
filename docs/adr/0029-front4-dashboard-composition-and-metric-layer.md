# ADR-0029 — front4 dashboard composition engine + calc/metric/graph layer

- **Status:** Proposed
- **Date:** 2026-07-18
- **Supersedes / extends:** [ADR-0028](0028-front4-refactor-modernization-roadmap.md) (front4 refactor roadmap — the *what/why*); this ADR is the *how* for the dashboard + metric layer.
- **Related:** [ADR-0026](0026-api-layer-consolidation.md) (API consolidation), [ADR-0027](0027-refdata-api-surface-1-read-contract.md) (refdata read contract).
- **Companion (to be authored in front4):** ADR-0030 — TypeScript seed (`allowJs` island). Tracked here as Decision D6; formalized repo-local when Phase A starts.

## Hard constraint (from the product owner)

> "The design, colors etc. should be roughly the same. I don't want the identity of the page going away — but make the page functional and not buggy."

This is a **functional/reliability refactor with a frozen skin.** Every tenant's dashboard must come out of the new engine **pixel-roughly-identical** to what they see today. Theme work is **de-duplication, not re-coloring** (tokens hold the *exact* current hex). Accessibility improvements are **additive only** (text/icon *alongside* color; no color changes for contrast in this scope). **Visual parity per tenant is a migration acceptance gate**, enforced by golden-master + screenshot-diff tests.

---

## Context

front4 renders factory OEE dashboards. Today the "Overview" surface is **8 near-duplicate `Overview*` page forks** (`src/routes.jsx`), each hand-wiring its own data fetching, polling, 12–24h full-page reload, MUI grid, and leaf components. The differences between forks are small (which tiles, layout, a few options) but the *scaffolding* — and therefore the *bugs* — is copy-pasted 8×. Which look a tenant gets is selected by **hardcoded enterprise/equipment ids scattered in JSX** (`enterprise==6||1||37`, `id_enterprise:31`, `lines=[404,411]`), violating the standing no-hardcoded-ids rule.

Three design lenses investigated this in parallel:

- **Lens A** — the per-client dashboard composition engine (tech-lead).
- **Lens B** — the calc/metric/graph component library + calc-correctness (frontend-dev).
- **Lens C** — the backend metric contract + the #80 `proportional_target` ruling (dba, read-only against **prod tsp12**).

Their findings interlock: **Lens C establishes backend truth → Lens B builds typed/tested widgets that render it → Lens A composes those widgets per tenant.**

---

## Decisions

### D1 — Collapse 8 forks to a widget-registry + per-tenant-config engine

The forks cluster into **3 families + 1 dead page**, not 8 unique things:

| Family | Forks | Shape |
|---|---|---|
| **A** (base) | `Overview` (v1), `OverviewV4`, `OverviewV5`, `overviewV7` | InfoUp{WithOP/WithoutOP/SetUp} + Card1 + Card2 + Chart(+Montbello) + Table + footer |
| **B** | `OverviewGranado` (v2), `OverviewV6` (Elpes) | Header + InfoUp + InfoSide + Chart + Table (+ V6 timeline/PLC) |
| **C** | `OverviewV3` | downtime-emphasis: AvailabilityGraph + status card + inline PLC + Table |
| **dead** | `OverviewSuzano` | **unrouted** (never imported in `routes.jsx`), hardwires ids `[404,411]` — see D5 |

`Overview` and `overviewV7` are **byte-identical (md5-proven) across all 7 leaf components**; V4 is `Overview` + 3 small additive deltas. So the real extraction target is **one canonical leaf set with prop-driven variants**, not 8 rewrites.

The engine is a thin, boring core — the *only* copy of the scaffolding:

```
<Dashboard dashboardId lineId>
  ├─ useDashboardConfig(dashboardId)          // refdata baseline ⊕ user override, zod-validated
  ├─ <DashboardGrid layout={config.layout}>   // one MUI Box, gridTemplateAreas verbatim from config
  │    └─ per widget:
  │         <Box gridArea>
  │           <WidgetErrorBoundary>           // ← per-tile blast-radius isolation (headline reliability win)
  │             <Suspense fallback={<WidgetSkeleton/>}>
  │               <WidgetSlot registry={REGISTRY} widget={w} scope={scope}/>
  └─ useDashboardRefresh(config.refresh)       // ONE reload timer + one poll clock (replaces per-fork setTimeout/pollInterval)
```

- **`REGISTRY`**: `{ [widgetType]: { component, hook } }`. Unknown type → labeled "unknown widget" tile, never throws.
- **Per-tile `WidgetErrorBoundary`** — today one failing query can blank a whole fork; here the blast radius is one tile. This is the direct answer to "functional and not buggy."
- **Layout = literal MUI `gridTemplateAreas`** copied from each fork — no new layout DSL, no `react-grid-layout`. Guarantees identical DOM/CSS → visual parity.

### D2 — Per-tenant dashboards are **config, not code**

Config is a zod-validated JSON document with three sections mirroring the three divergence axes (which widgets / layout / per-widget options). The hardcoded id literals become config values:

- Chart variant switch (`enterprise==6||1||37` → `ChartMontbello`) → `ProductionBarChart.options.variant`.
- Elpes (`id_enterprise:31`) → a tenant config row.
- Suzano multi-line (`lines=[404,411]`) → `scope.lineIds[]` (D5).

V4 stops being a file: it's `Overview` config + `{ showPreviousOrder: true, footerVariant: 'v4-divider' }`. That its divergence is expressible as *flags* is the tell that copy-paste was never warranted.

**Storage:** a new tenant-scoped `dashboard_config(id_enterprise, dashboard_id, config jsonb, version, updated_at)`, exposed as a refdata dataset with `pEnterprise=$1` (passes the ADR-0027 `tenancy_isolation_test.go` structural gate for free). Resolution order at render: `user_screen_config` per-user override (already built, ADR-0027) → tenant `dashboard_config` baseline. Rejected: embedding config in the `v_menu_per_user_role` JSON (overloads nav, couples layout lifecycle to menu lifecycle) and bundling JSON in front4 (makes "new variation" a deploy again).

### D3 — Widgets are a **typed, tested, memoized** component library; buggy client math is **deleted, not ported**

New home: `src/components/metrics/` + `src/components/charts/` + `src/lib/` (pure fns + DTO types). Each widget: theme-token-driven (no hex), built-in `<AsyncState>` (loading/empty/error), `React.memo`-wrapped, `data-testid` for golden-master, renders **pixel-identical** to today.

The confirmed calc bugs are replaced by pure, typed, unit-tested functions in `src/lib/format/` + `src/lib/oee/`:

| # | Location | Bug | Replacement |
|---|---|---|---|
| B1 | `utils.js:258-285` `secondsToDurationString` | debug `console.log`; **RangeError** on billions-range `running_time` (int4-overflow echo) via `new Date(v*1000).toISOString()`; garbage on negatives | `formatDuration(seconds)` — integer d/h/m/s, no `Date`, explicit overflow/negative/`null`→`"—"` |
| B2 | `utils.js:516-529` `getValueFromObjectPath` | returns `o` — **ReferenceError** (undefined var); never exported | Delete; typed `getPath` only if needed |
| B3 | `utils.js:363-370` `float` | hardcoded `maximumSignificantDigits:3` → **silently truncates** (`12345→"12,300"`) | `formatNumber(value,{maxFractionDigits})` via `Intl.NumberFormat` |
| B4 | `utils.js:333-357` `roundNumber` | K/MM built on broken `float`; dual return | `abbreviateNumber(value)` → typed `{value,unit}` |
| B5 | `Card1/Card2.jsx` `howGood` | `quanto==99\|\|quanto==101` — **float `==` on int points**; ±1% "hide arrow" dead-zone **never fires** → misleading arrow; hardcoded hex | `goalDelta(actual,target,{tolerancePct=1})` → `{direction,deltaPct}` → theme tokens |
| B6 | `configurations/scrap.js` `scrapCalc` | localStorage-driven, `=="Infinity"` string compare | `scrapPercent(type,gross,net)` pure/typed (keep the 2 legit formulas) |
| B7 | `graphqlConnection.js:112` | `watchQuery.errorPolicy:'ignore'` — **app-wide silent failure** | flip to `'all'`, surface via `<AsyncState>` |
| B8 | `graphqlConnection.js:120-124` | `concat(auth, httpLink, retryLink, errorLink)` — `httpLink` **terminates** before retry/error links → they're **dead** | reorder to `from([auth, errorLink, retryLink, splitLink])` — **coordinate with backend-dev before touching transport** |

**Widget catalog** (extracted verbatim, visual parity = the extraction's acceptance test): `OeeScore` (+ dedup the 3 A/P/Q columns and the identical SHIFTS/TEAMS blocks into `OeeComponentColumn`/`OeeBreakdownRow`), `KpiStatTile`, `TargetDeltaTile` (consumes B5 fix; #80 target field as a prop), `ProductionBarChart` (Montbello + Granado threshold-color = a `variant`/`colorMode` prop), `EventsTable` (a11y text+icon, stable keys, virtualize), `MachineTimeline` (**fixes the `changeOver`/`stopped` same-`#C13939` bug** → distinct tokens + legend + aria), `JobInfoPanel`/`OrderRow`/`Metric`/`ProgressBar` (from the 826-LOC InfoUpWithOP). Shared: `<AsyncState>`, `<MeterBar>`, and `statusColor(theme,status)` replacing ~19 copy-pasted `getColor`/`mainColorStatus` definitions.

**Charting:** one lib (recharts 2.1.2, no new dep), a `chartTheme` module centralizing the copy-pasted axis/grid/margin/hex, dataviz-skill palette (production=primary, scrap=error, target=success reference). **The single biggest perf win is `React.memo`+`useMemo`** — there is currently **zero `React.memo` in the codebase**, so every chart repaints and re-derives its config on every 55s poll tick (referential-identity churn). Memoize at the widget boundary; pass stable data/config from the engine.

### D4 — The metric contract (backend truth; front4 stays thin)

`uns_equipment_current_{job,shift,day,month,week}` and `_metrics` are **precomputed snapshot tables** (each has `last_updated`), written by `piot_uns_*_refresh_current_*()` from the `equipment_runtime_*` rollups on the pg_cron cadence. **All OEE math lives in the `piot_get_*_production` stored procs**, spot-checked sound against the OEE identity:

```
oee   = net / ideal_production          (= A·P·Q)
oee_a = running_time / available_time   (availability)
oee_q = net / gross                     (quality)
oee_p = oee / (oee_a · oee_q)           (performance, derived)
```

front4 does **zero** OEE math (the sole exception is the #80 override, deleted in D-next). The DTO contract front4 mirrors = the **explicit column projection** of these snapshot tables (full catalog in the Lens C appendix). Typing rules the DTOs must encode: `oee*`/`target`/`proportional_target`/`speed` are `real` (**float32 — round for display, never `===`-compare**); time buckets are `int` seconds; **every metric is nullable** (idle machine → NULLs, not zeros — the existing `?.` chains assume this); **never re-derive proportional metrics from `elapsed_time`** (its elapsed basis ≠ the proportional's basis — see #80).

### D5 — #80 `proportional_target`: **backend is authoritative → delete the front4 override**

Verified SELECT-only against **live prod `pg_proc`** (not the committed parity file — decisive, see D7). In prod, `piot_get_equipment_runtime_shift_production` has an **active** second write:

```sql
set proportional_target = target * (extract(epoch from now() - ts_value) / shift_size)
```

i.e. elapsed-prorated, same intent as the day formula. **Live proof** (mid-shift, elapsed_frac 0.678): backend shift `proportional_target/target = 0.676` vs front4's own override `0.678` — **agree to 0.3%** (gap = cron-refresh lag). **The DB calc is correct.** The `não está correto` comment is **stale** — it describes the pre-fix full-shift-target formula.

**Ruling:** delete the override in `Overview/components/Card1.jsx:111-115` and `OverviewV5/components/Card1.jsx:108-115`; consume `uns_equipment_current_shift.proportional_target` directly (as Day/Month already do). The backend denominator (`shift_size`, planned-downtime-aware) is *more* principled than front4's wall-clock `duration` — deletion is a correctness improvement, not just a simplification. Closes #80.

`OverviewSuzano` is **deleted, not migrated** (D1): it's unrouted dead code. Its 2-machine aggregation is the *motivating requirement* for the engine's `scope.lineIds[]`+`aggregate:'sum'` feature — the requirement is preserved, the code is not.

### D6 — TypeScript seed (companion ADR-0030, `allowJs` island)

Reality check: **ADR-0028 is an open PR** (not merged), front4 has **no tsconfig and zero `.ts` files**. So Phase A *authors* the seam rather than aligning to a doc that isn't there: `tsconfig.json` (`allowJs:true, checkJs:false, strict:true, jsx:preserve`) — Vite's esbuild already handles `.ts/.tsx`, no bundler change. `.ts` for DTOs + pure fns, `.tsx` for new widgets, existing `.jsx` untouched. The DTO types are the **contract seam with the backend** (D4): if refdata exports the metric types, front4 imports them; otherwise these are the front4-side mirror to reconcile with backend-dev.

### D7 — Migration hazard: reconcile the parity-port file to prod

The committed `edge-node-red/db/20-oee-engine-parity.sql:~13120` has the shift `proportional_target` elapsed-proration write (#80's fix) **commented out** — it **diverges from live prod**. Any re-apply, or a Calc/Go cutover (#276) derived from it, would **regress `uns_equipment_current_shift.proportional_target` back to the full-shift target, resurrecting bug #80.** Add "shift `proportional_target` elapsed-proration active" to the cutover parity checklist (ADR-0022 gate) and reconcile the file to prod.

---

## Strangler migration (per-tenant, reversible, visual-parity-gated)

The existing indirection is the seam: `v_menu_per_user_role.menu` is a per-(enterprise,role) JSON array of nav URLs (`ListaSideBar.jsx` already appends a generic `dataset`/`reportId` param — precedent for carrying `dashboardId`).

1. Build engine + catalog + data hooks; widgets lifted **verbatim** (extraction acceptance = screenshot diff vs original).
2. Author a `dashboard_config` per existing fork that **reproduces it exactly** (grid areas, widget list, flags).
3. Add route `overview/d/:lineId/:dashboardId`; old `overview/vN` routes stay live.
4. **Parity harness (qa):** render fork vs engine for the same `lineId` at the same instant → assert (a) screenshot diff under threshold **and** (b) widget datasets byte-equal.
5. **Cut one tenant:** flip its `menu_items[].URL` from `/overview/vN/:lineId` to `/overview/d/:lineId/:dashboardId`. Bake a shift cycle.
6. **Rollback = flip the URL back.** No deploy.
7. When a fork's **last** tenant is migrated + baked → delete the fork dir + route.

**Bespoke escape hatch (3 tiers, so "custom" never means "fork the app"):** (1) config expresses it (layout + options + `scope`); (2) a registered `custom:*` widget slot in `src/widgets/custom/` — a bounded, error-isolated tile, not a new page; (3) full-custom route mounting inside app chrome + reusing widget hooks — ADR-worthy exception, explicitly rare.

---

## Sequenced task board

**Phase A — Test net + TS seed (first; unblocks everything)**
- A1 (S) Wire `vite.config` `test.setupFiles`; shared ResizeObserver stub; add `msw` + Hasura `uns_equipment_current_*` handlers.
- A2 (S) `tsconfig.json` (allowJs) + author front4 ADR-0030 (TS seed).
- A3 (M) DTO types `src/lib/dto/*.ts` from the D4 catalog (reconcile ownership with backend-dev/refdata).
- A4 (M) Golden-master snapshots of current OeeScore/Card1/Card2/Chart/Table/InfoUpWithOP with an **adversarial fixture set** (`null`, billions-range `running_time`, `oee>1.0`, `elapsed_time=0`, negative durations, `target=0`) — this captures B1–B6 as documented failing snapshots.

**Phase B — Pure calc fns (delete-not-preserve)**
- B1 (M) `src/lib/format/`: `formatDuration`, `formatNumber`, `abbreviateNumber` + tests; delete broken `getValueFromObjectPath`.
- B2 (S) `src/lib/oee/`: `goalDelta` (fixes the never-firing dead-zone), `scrapPercent` + tests.
- B3 (S) Flip `errorPolicy:'ignore'→'all'`; build `<AsyncState>`. **Flag B8 (Apollo link ordering) to backend-dev** — don't rewire transport unilaterally.

**Phase C — Theme tokens + status color (dedup, not re-skin)**
- C1 (M) Rationalize `Global/theme/index.js`: distinct tokens for `stopped`/`changeOver`/`warning` (fixes the same-red bug), fix `blue`→green misname, drop dead double `background.default` — **exact hex preserved**.
- C2 (S) `statusColor(theme,status)` replacing the ~19 copies.

**Phase D — Widget extraction (each: extract → snapshot-green → memo → additive-a11y)**
- D1 (L) `OeeScore` + `OeeComponentColumn` + `MeterBar`.
- D2 (M) `KpiStatTile` + `TargetDeltaTile` (#80 field as prop).
- D3 (L) `JobInfoPanel` + `OrderRow` + `Metric` + `ProgressBar` (from InfoUpWithOP).
- D4 (M) `EventsTable` — statusColor, a11y text+icon, stable keys, virtualize, states.
- D5 (S) `MachineTimeline` — fix `changeOver`/`stopped` collision + legend + aria.

**Phase E — Charting**
- E1 (M) `chartTheme` + `<Chart>` primitive; tokenize inline hex; dataviz palette.
- E2 (M) `ProductionBarChart` (`colorMode` covers Montbello + Granado variants); `React.memo`+`useMemo`.

**Phase F — Composition engine**
- F1 (M) Config schema (zod) + `<Dashboard>`/`DashboardGrid`/`WidgetSlot`/`REGISTRY`/per-tile `WidgetErrorBoundary`/`useDashboardRefresh`.
- F2 (M) `dashboard_config` table + refdata dataset (`pEnterprise=$1`) + baseline⊕override client (dba+backend-dev).
- F3 (S) Data-hook layer (one hook per D4 dataset, Apollo-cache dedupe).
- F4 (S) Author the reproduction configs per fork (seed migration).
- F5 (S) Route `overview/d/:lineId/:dashboardId` + menu-URL repoint tooling + rollback runbook.

**Phase G — Cutover (qa-gated)**
- G1 (M) Visual+data parity harness (screenshot diff + dataset diff), per fork.
- G2 (S each) Per-tenant menu-URL cutovers, gated by G1; delete a fork when its last tenant is baked.
- G3 (S) Delete dead `OverviewSuzano`; collapse `overviewV7` into `Overview`.

**Backend follow-ups (out of front4, tracked here)**
- H1 (S) #80: after front4 deletes its override — no backend change needed (prod is correct); **but** reconcile the D7 parity-file divergence and add the cutover-checklist line.
- H2 (M) refdata: turn `liveUNS` `SELECT *` into the D4 explicit projections (ADR-0027 design-rule #2); confirm week-snapshot need; land the ~13 net-new direct-Hasura reads as datasets.

**Critical path:** A → B/C (parallel) → D (parallel) → E → F → G. #80 override deletion rides D2; it is *not* blocked (prod backend is already correct).

---

## Consequences

**Positive:** one scaffolding copy (bugs fixed once); "client wants it different" = a config edit, not an `OverviewV8`; hardcoded-id rule satisfied; per-tile error isolation; the calc bugs (#80, #81) deleted with a paper trail; visual identity provably preserved (golden-master + per-tenant screenshot gate); a typed island that can grow.

**Negative / risks:** the widget catalog is intentionally non-minimal (one widget per distinct rendered tile — visual parity forbids collapsing two looks into one); Phase A test-net is upfront cost before any visible win; the D7 parity-file divergence must be fixed before the #276 Calc cutover or #80 regresses; ADR-0030 (TS) adds a language to a JS codebase (mitigated by `allowJs` — zero forced migration).

**Open questions for the product owner:** (1) config-authoring UI for CS-Admin now, or seed via SQL/refdata-PUT first? (recommended: seed first, UI is off critical path); (2) do customers get self-service tile rearrangement via the `user_screen_config` override layer, or is config CS-Admin-owned? (decides whether the authoring UI is P1 or P3); (3) migrate the stubbed `PlcStatusTile` as-is for parity and wire the real `/infra-events/plc` endpoint later — confirm.
