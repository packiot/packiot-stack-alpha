# ADR-0028 — front4 Refactor & Modernization Roadmap

**Status:** Proposed · **Date:** 2026-07-18 · **Builds on:** ADR-0026 (API consolidation), ADR-0027 (refdata Surface-1) · **Source:** a 6-lens read-only audit of front4 @ `development` (architecture · data-layer · perf/build/deps · testing · security · UX/a11y).

## Context

front4 is the product SPA (React 17 + Vite 3.2.2, ~36.7k LOC, 289 files, **0% TypeScript**, FTP-deployed). It's functionally rich but architecturally un-consolidated, and it's now mid-way into the ADR-0026/0027 migration off Hasura to refdata-api (Phase-1 live on staging). This roadmap sequences a refactor that **modernizes the app AND carries the refdata migration on its back** — one coherent program, not two competing ones.

The six audits **converge hard**, which is the strongest signal in here: every lens independently surfaced the same top items. That convergence is what makes the sequencing below trustworthy.

---

## 0. The one item that isn't a refactor — it's an incident

**The Hasura `x-hasura-admin-secret` is shipped in the browser bundle** (`src/utils/graphql-client.js:19`, used by `OverviewV6` + `overviewV7` via a hand-rolled `useQuery` that deliberately sends the admin secret instead of the JWT). The security lens's git-ref check found it on **`origin/master` AND `origin/development`** (same commit `67c30db`; introduced `4798dac9`, 2025-10-28). **If `master` builds prod, that secret has been live in the public production bundle for ~3 months** — `x-hasura-admin-secret` bypasses all Hasura permissions → full read/write/delete over the entire prod DB, all tenants, zero-auth, readable by anyone via DevTools.

This **pierces the "repos are private" posture**: private repos protect git-history secrets, but this one is *served to every browser in prod*. It is not a refactor task; it is a **rotate-now** task (tracked: #58/#61). Deleting the code does not un-leak a shipped secret.

**Immediate (owner-gated):** (1) rotate the Hasura admin secret on the prod console; (2) confirm which branch builds prod. **Code (Phase 0 below):** delete `graphql-client.js`, route V6/V7 through the JWT Apollo client, add a CI secret-scan/merge-guard, block `master→*` until excised.

---

## Synthesized findings (what all six lenses agreed on)

| Theme | Evidence (measured) | Lenses |
|---|---|---|
| **Browser admin secret** | on master; `x-hasura-admin-secret` in the 9.5 MB bundle | arch, data, sec, test |
| **8 near-duplicate Overview pages** | `Overview`,`Granado`,`Suzano`,`V3–V7` — 80–95% clone, ~25% of the codebase (~9.6k LOC); routed by a DB `menu` blob (no static reachability) | arch, data, UX |
| **Zero code-splitting** | 1 monolithic chunk, **2.76 MB gzip**, 0 `React.lazy` | perf, arch |
| **~0% test coverage** | CI runs **no** tests; 4 of 5 existing specs are **red**; test-utils hits **prod Hasura** | test |
| **Data layer: 3 hand-rolled clients, errors swallowed** | Apollo `errorPolicy:'ignore'` → failed reads render blank ≈ "idle machine"; 21 per-page `queries.js`; `fetchPolicy:'no-cache'` (Apollo cache paid-for, unused) | data, test, UX |
| **api_key + tenant in the browser** | `VariablesContext` puts `enterprises[0].api_key` in localStorage; mutations send `?token=api_key&idEnterprise=`; hardcoded `id:33`/`in_id_enterprise:31` | sec, data, UX |
| **Dual UI libs + 4 styling paradigms + theme bypass** | MUI v4 (95 files) **and** v5 (205); `sx`+styled-components+inline+makeStyles; `#407CCC` typed 170× (= `primary.main`); `stopped` ships as **two** reds | UX, perf, arch |
| **Stale/heavy deps** | Vite 3 (5 majors old), React 17, Node 16 (EOL), moment **and** dayjs, **52 npm vulns (2 critical** in the deprecated Apollo-WS stack, which has **0** live subscriptions), `npm` itself a runtime dep | perf, sec |
| **No resilience/perf hygiene** | 0 ErrorBoundary; 4/289 files memoize; timers in render bodies; `ws://` plaintext JWT; Downtimes pulls full history client-side | arch, perf, sec, UX |
| **a11y ≈ 0** | color-only machine status (`stopped`==`changeOver` same red), 4/51 icon-buttons labeled, status palette fails WCAG contrast (2.35 vs 4.5), no landmarks | UX |

**Verdict shared by all lenses:** the bones are fine (feature-folders, MUI-v5 base, a real theme, a real i18n mechanism). The disease is **"copy the file / retype the value when the requirement varies"** instead of parameterizing — 8 Overview forks and a 170×-retyped color are the same disease at two layers. The fix is **consolidation, not rewrite.**

---

## The two central architectural bets

Everything sequences around these:

1. **A `data-access` seam over TanStack Query (react-query v4).** Pages import typed hooks (`useOverviewTimeline()`), never a client. One `data-access/datasets` module hides Hasura-vs-refdata-vs-edge-api and normalizes both to the same row shape. **A read migrates when its dataset fn flips transport — the page never changes.** This single move: (a) makes refdata Phases 2-4 one-dataset-per-PR + instantly revertible, (b) replaces the 3 hand-rolled `useQuery` clones + the unused Apollo cache (react-query gives caching/dedup/polling/`{isLoading,error}` for free), (c) is where TypeScript DTO types get seeded. *Do not grow the POC's `useRefdataQuery` into the 37-read abstraction — demote it to react-query's `refdata` transport.*

2. **A shared OEE dashboard component library.** Extract `KpiStatTile`, `ProductionBarChart`, `LastEventsTable`(+`statusColor(theme,status)`), `OeeSidePanel`, `JobStatusPanel`, `formatDuration`, one `overview.queries`. Then the 8 Overview pages become thin layout+config over shared parts. **Governance rule: per-customer variation is a prop/config, not `OverviewV8`.**

And the safety rail that makes both non-scary:

3. **A parity-test harness** — `expectReadParity(fixture, oldSelector, newSelector)`, one per migrated read, deep-equal on the projected view-model. This is `tsp12==F2==F3` applied to the browser: a swapped read must render byte-identical or the diff is documented. **No read migrates without a parity test in the same PR.**

---

## Phased roadmap

Effort: **S** ≤ ~1 sprint · **M** ~1 month · **L** multi-month. Phases are ordered so each de-risks the next; within a phase, items are independent unless noted.

### Phase 0 — Stop the bleed (now; no migration dependency) — **S**
- **Rotate the Hasura admin secret** (owner, prod) + confirm prod build branch. *(load-bearing)*
- Delete `graphql-client.js`; route `OverviewV6`/`overviewV7` reads onto the JWT Apollo client; drop the `id:33` hardcode.
- **CI secret-scan + merge-guard** (gitleaks) on PRs into dev/staging/master; block `master→*` until the secret is excised. (front4 has *no* PR-triggered workflow today — this is also the hook for Phase 1's test gate.)
- `ws://` → `wss://` in `graphqlConnection.js`.
- `npm audit fix` the leaf vulns; remove the runtime `npm` dep + misplaced `axios-mock-adapter`/unused `react-select`.
- Delete `package-lock.json` (yarn is authoritative); CI to Node 20 + dependency caching; renew the MUI Pro license key (expired 2023-04) → env var.
- **Payoff:** closes a live prod credential exposure + kills the 2 critical vulns + a clean CI baseline. All independent, all cheap.

### Phase 1 — Build the test safety net (before any refactor) — **S→M**
- Wire `setupFiles`; rebuild `test-utils.jsx` to inject a **mock** client + **MSW** (it currently hits prod Hasura); fix/delete the 2 red specs so `main` is green.
- Add `@vitest/coverage-v8`; **PR-triggered `test.yml`** as a required check; gate `staging`/`master` deploys on it (`needs: test`); add `eslint` + `eslint-plugin-jsx-a11y`.
- Unit-test the pure calc/format helpers in `utils.js` with adversarial inputs (null/NaN OEE, billions-range durations, negatives) — highest leverage-per-hour.
- Adopt Playwright (retire Cypress 8 — pre-v10, commits secrets); one login→dashboard smoke.
- **Payoff:** refactoring stops being blind. Required before Phases 2-4 touch data.

### Phase 2 — Land the data-access seam (behavior-neutral) — **M**
- Introduce react-query `QueryClientProvider` + `data-access/datasets` + a single `auth/getToken.ts` (kills the 3× `delay(2500)` token hack).
- Wrap **existing** Apollo reads behind dataset fns **without changing transport** — no behavior change; this is the refactor that makes everything after it one line.
- Flip `errorPolicy` to `'all'`; introduce a shared `<AsyncState>` (loading/empty/error) + a top-level + per-tile **ErrorBoundary**. (Fixes the blank-vs-idle correctness trap.)
- Delete the dead WebSocket/`subscriptions-transport-ws` stack (0 subscriptions).
- **Payoff:** the seam + resilience primitives; unblocks the migration to be per-dataset.

### Phase 3 — The refdata migration through the seam (ADR-0026 Phases 2-4 / closes #58) — **M→L**
- **Critical-path dependency:** refdata's Firebase-JWT auth path (backend — done: #68) must be verified live before any browser read moves. *(gate)*
- **Migrate the `GET_VARIABLES_CONTEXT` bootstrap read first** — it's the only reason `api_key` enters the browser; moving it lets you delete `localStorage.setItem("api_key")` and the `?token=api_key` mutation coupling. Biggest security win.
- Then reads by dataset (~24 covered + ~13 net-new), **one flag-gated, parity-tested PR each**.
- Migrate the writes to JWT-authed edge-api; **then delete Hasura-from-browser → close #58.**
- Split `VariablesContext` as you touch it (identity/permissions vs filter-state vs UI); memoize the provider value.
- Seed **TypeScript** here — type the refdata DTO contracts at birth; new files land `.tsx`. (~80% of the bug-catching value for ~20% of a full TS migration.)
- **Payoff:** zero secrets in the browser, JWT-only, server-derived tenant — the structural end of the whole #58/#61 class; Hasura-from-browser retired.

### Phase 4 — Structural consolidation (the big, front-loaded-value arcs) — **L**
- **De-duplicate the dashboards** (bet #2): extract the shared OEE component library, then collapse `V1/V4/V7` first (90–95% identical, lowest risk). *Gate deletions on prod `menu`/`v_menu_per_user_role` usage telemetry (dba) — a fork may be a live tenant's route.*
- **Theme as single source of truth:** fix its duplicate keys, add a grey ramp + spacing scale, then ESLint-ban raw hex → replace the 170× `#407CCC` with `theme.palette.*`. Cheap, fixes most visual inconsistency.
- **Kill MUI v4** (codemod the 95 files → v5) + standardize styling on `sx`+`styled()` (drop styled-components + inline). Do this *after* the shared components exist so you migrate them once, not seven times.
- **moment → dayjs** (already partly started; 72 files, mechanical), one icon set, **Vite 3→6** (incrementally, after code-splitting so chunk output is legible), **route-level `React.lazy`** (halves time-to-interactive on floor tablets).
- **Payoff:** ~25% codebase reduction, one component vocabulary, a bundle a factory tablet can load.

### Phase 5 — Polish & hardening (fold into normal maintenance) — **S→M each**
- **a11y to WCAG 2.1 AA:** never signal status by color alone (fix `stopped`==`changeOver`), re-pick the status palette for contrast, `aria-label` the 51 icon-buttons, `alt` on images, one `<h1>` + `<main>`/`<nav>` landmarks. (Top items are S and high-visibility.)
- Centralize **i18n** (in-repo key catalog or `react-i18next` over the existing packs; lint untranslated literals; fold the parallel Moment-locale path).
- **Server-paginate** the Downtimes/scan lists (currently full-history-to-client).
- Render hygiene: `React.memo` chart/tile leaves, timers out of render bodies, audit `pollInterval` cadences, replace `window.location.reload` timers with refetch.
- Add a **CSP** at the serving layer; move the JWT off localStorage where feasible; stop `console.log`-ing tokens.

---

## Sequencing rationale & dependencies

- **Why safety net (Phase 1) before the seam/migration:** every lens said the same — a swapped read or a renamed field renders *wrong OEE to a factory customer* with nothing to catch it. The parity harness is the browser's `tsp12==F2==F3` gate; it must exist before reads move.
- **Why the seam (Phase 2) before the migration (Phase 3):** the seam makes each read-swap a one-line, revertible, parity-tested change instead of a page rewrite.
- **Why consolidation (Phase 4) after the migration seam but its component-extraction can start in parallel:** extract shared components *before* the MUI v4→v5 codemod so you migrate them once. The Overview-fork *deletions* are gated on **prod `menu` telemetry** (dba) — you cannot statically know which forks are dead.
- **Critical-path external dependency:** refdata backend JWT auth (#68, done) + refdata publicly reachable (#78, done) — both cleared. The remaining backend coupling is confirming edge-api/back4 derive uid+enterprise from the JWT (not the client `uid` header) — a one-answer check (backend-dev) that decides whether the client-supplied-tenant items are exploitable IDOR or defense-in-depth.

## Rough sizing (order-of-magnitude, one focused frontend pair)
Phase 0 ≈ days · Phase 1 ≈ 1 sprint · Phase 2 ≈ 3-4 weeks · Phase 3 ≈ 1.5-2 months (paced by read count) · Phase 4 ≈ 2-3 months · Phase 5 ≈ continuous. **Phases 0-2 (~6 weeks) deliver the security fix, the safety net, and the seam — the foundation everything else stands on.**

## Explicitly NOT worth doing (audit consensus)
- **Don't** reorganize the top-level folder taxonomy — it's adequate; the pain is duplication, not location.
- **Don't** big-bang the TypeScript migration or the MUI v4→v5 swap in one PR — both are morale sinks; do them incrementally, on-touch, seam-first.
- **Don't** adopt a *new* UI library (Chakra/Ant) — MUI v5 is the correct, boring choice for a data-dense B2B tool; a new lib just creates a fourth paradigm.
- **Don't** rush React 17→19 — highest blast radius, least user-visible payoff; let MUI-v5 + Vite land first.
- **Don't** delete any Overview fork before you have prod `menu` usage data — you'll break a tenant.

## Consequences
- **Positive:** a live prod credential exposure closed; a real test net; the refdata migration becomes safe/mechanical; ~25% less code; one UI/data vocabulary; a factory-loadable bundle; an a11y baseline. The refactor and the Hasura-retirement move *together*.
- **Costs:** Phase 4 is genuinely multi-month; the parity discipline (Phase 1/3) is real per-read overhead — but it's the overhead that keeps a swapped read from silently shipping a wrong number to a factory.

## Open questions for the user
1. **Which branch builds prod?** (decides how urgent the admin-secret rotation is — likely already-live.)
2. Do we want the Overview-consolidation to also unify the per-tenant *branches* (`cpackOverview`, `incoplastOverview`, `suzano`, `montbello`) into config, or keep them as deploy-time variants?
3. TypeScript: seed-DTOs-only (recommended) vs commit to a fuller migration over time?
4. Staffing/pace — is this one frontend pair over a quarter, or a squad sprint on Phases 0-2 then steady-state?
