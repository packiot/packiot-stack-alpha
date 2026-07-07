# ADR-0018 — Operator + frontend integration makeover: retire the Node-RED BFF, one read/write split everywhere

- **Status**: Proposed (2026-07-07) — decider: Emmanuel Podestá.
  Wave 1 (safe-now hygiene) executed same day: operator4 #87,
  edge-api #137. Everything else here is the plan those PRs serve.
- **Context inputs**: three implementation audits (operator SPA,
  edge-api, front4) run 2026-07-07; findings inline below.

## Context

The operator SPA's entire API surface (19 routes via nginx) terminates
in **edge-nodered's API tab — a de-facto backend-for-frontend**: reads
resolve via the GraphQL tab (Hasura), writes are payload-shaped and
forwarded to edge-api, and login (`/session`) mints a JWT from users
seeded in the *flow config JSON* (plaintext compare, `'packiot'`
fallback secret). front4 (prod product frontend) reads **67 distinct
GraphQL root fields** from prod Hasura (52 reads / 15 writes) and
leaks the enterprise `api_key` to the browser. Both frontends predate
the stack's read/write split (refdata-api reads · edge-api writes ·
worker owns math) and block retirements: the Node-RED operator tab,
Hasura, and the GraphQL refresh chain.

Known live bug (documented in operator #87): the SPA's
`/production-orders/create` call matches neither the nginx proxy nor
any Node-RED handler — the SPA catch-all returns index.html + 200 and
the "create new PO" flow silently no-ops while reporting success.

## Decision (target architecture)

One rule for every frontend: **reads → refdata-api, writes → edge-api,
auth → edge-api session usecase.** No BFF, no GraphQL, no client-side
tenant authority.

```
operator SPA ──reads──► refdata-api (/v1/*)
             ──writes─► edge-api    (/api/*)   → user_logs (replay contract)
             ──login──► edge-api    /api/session/login
front4       ──reads──► refdata-api (10 fixed routes + ~11 /v1/catalog datasets)
             ──writes─► edge-api + admin write surface (NOT refdata)
edge-nodered: API tab + GraphQL tab + nginx BFF proxy RETIRE
```

### Operator cutover contract

- Reads map 1:1 onto existing refdata routes (the C1 "10/10" set);
  response-envelope adapters live in the SPA's single client module
  (`src/Services/endpoints.js`, created in wave 1 — cutover is a
  per-function base swap).
- Writes go to the already-frozen edge-api routes (mirror-replay
  contract unchanged). The Node-RED payload-shaping moves into the
  SPA's client module; the duplicated `idEquipment`/site/area
  derivation (4 copy-pastes) centralizes there too.
- `/session` ports to `src/usecases/session/login/` in edge-api:
  same response shape `{status, user_permissions, entities, user,
  language, token}` (the SPA's AuthContext/VariablesContext topic
  canonicalization is the highest-risk surface — add doubled-segment
  fixture tests BEFORE cutover), JWT secret REQUIRED from env (no
  fallback), entities from the entities-per-user-role view.
- **OPEN DECISION (owner: Emmanuel)** — credential storage: the DB
  `users` table has NO password column (identity is Firebase);
  Node-RED's users live in flow-config JSON. Options: (a) add
  `users.operator_pw_hash` (bcrypt) + CS-Admin management [lean],
  (b) per-factory client.yaml credentials, (c) delegate to Authentik
  (already fronts the SPA — long-term best, biggest change). Login
  events get a NON-replayed eventType (or no logData) so replay
  never replays logins.
- MSW `handlers.js` + `fixtures.js` must flip to the new contracts in
  the SAME PR as the cutover — the 204-test suite pins the old
  envelopes and would green-wash a broken cutover otherwise.

### front4 contract (executes at Phase F, designed now)

- 10 existing fixed refdata routes cover the operator-shaped reads.
- ~11 new `/v1/catalog` datasets cover the rest: oee,
  live-uns-equipment, mission-control, overview-detail,
  downtimes-analytics, total-production, single-period, machine-speed,
  production-flow, targets, enterprise-config. Most `h_piot_*`
  functions already take `(in_begin_time, in_end_time, in_ids_*)` —
  the contract is a rename into `{window, filters}`.
- **Security fixes bundled with the cutover**: stop returning
  `api_key` to the browser (X-Api-Key resolved server-side);
  hardcoded `in_id_enterprise: 31` in `OverviewV6/index.jsx:45`
  becomes context-derived (never-literals directive).
- The 15 Hasura mutations are OUT of refdata scope — they need a write
  home (edge-api + an admin write surface) before Hasura can retire
  for front4. Orphaned screens (OverviewSuzano, PdfSuzano) and the
  7-way Overview duplication are front4-repo cleanup, not contract.

## Wave plan (each wave = one PR set, one bake where it touches writes)

| Wave | Scope | Gate |
|---|---|---|
| 1 ✅ | operator client module + debloat (#87) · edge-api hygiene (#137) | none (safe-now) |
| 2 | edge-api `/session` usecase + credential decision + Idempotency-Key dedup on the 7 frozen replay routes | credential decision (human) |
| 3 | operator read-cutover to refdata (per-endpoint envelope adapters + MSW contract flip) + nginx v2 (`/v1/*` → refdata, `/api/*` → edge-api) | post-flip (rides C3's window) |
| 4 | operator write-cutover to edge-api (incl. the real `/production-orders/create` fix) + session cutover; retire Node-RED API tab + GraphQL refresh links | wave 2+3 green |
| 5 | edge-api flip-gated items: `SELECT *` → explicit DTO on production-information, `scanned_boxes` quarantine, DAO `throw new Error` → HttpException (replay sees a 4xx instead of 500 — coordinate with mirror-worker DLQ semantics) | post-flip |
| 6 | operator MUI v4→v5 collapse + styled-components removal; centralize id derivation | anytime post-3 |
| F | front4: refdata catalog datasets + api_key/enterprise-31 fixes + write-surface decision | Phase F (prod) |

## Consequences

- Positive: the operator survives every planned retirement (Node-RED
  tab, Hasura, GraphQL chain); frontends stop carrying tenant
  authority; one client seam per app makes future backend moves
  1-line; the G6 enumeration (front4's 67 root fields) is DONE from
  code — prod Hasura creds no longer block contract design.
- Negative: three cutover bakes (reads, writes+session, front4);
  a new auth surface in edge-api to operate; MSW contract flips are
  easy to forget (called out per-wave above).
- Risks named: AuthContext topic canonicalization (fragile,
  under-tested — fixture tests first); replay-contract freezes
  (routes AND eventType strings AND `?token=` auth stay until the
  flip retires the mirrors).

## References

Audits 2026-07-07 (operator/edge-api/front4, session memory
`full-stack-review-2026-07-07` addendum) · ADR-0009/0010 (why
Node-RED shrinks) · ADR-0015 (refdata/query API) · ADR-0016 §6
(retirement list) · ADR-0017 (process end-state this aligns to) ·
`overview/07` Phase C/F (sequencing this rides).
