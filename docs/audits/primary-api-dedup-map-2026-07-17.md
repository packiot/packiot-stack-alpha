# primary-api ↔ edge-api DEDUP MAP + retirement plan (ADR-0026 Wave 1, task #54)

**Date:** 2026-07-17 · **Status:** Analysis / planning artifact — **no endpoint deletions or redirects in this task** · **Owner:** backend · **Gates:** ADR-0026 step 4-5 (fold + retire primary-api). Execution waits on the access-log "has a live caller?" evidence being gathered in parallel.

## Scope & method

- **primary-api source:** `/home/podesta/github/packiot/api` — package name `primary-api`, git remote `github.com/packiot/api`. (The sibling dir `/home/podesta/github/packiot/primary-api` is *only* infra `containers/`, not the app — a trap; the app lives in the `api` repo.)
- **edge-api source:** `/home/podesta/github/packiot/edge-api`.
- Method: enumerated every `@Controller` + method decorator in both repos, then read the primary-api controllers + a representative sample of services to compare **effect, contract (request/response shape), auth model, and tenant-isolation**. Verb/path differences alone do not make a DIVERGENT — behavior does.

**Classification key**
- **EXACT-DUP** — edge-api has a behaviorally-equivalent endpoint (same effect, same/compatible contract, same audit convention). Retire by caller-migration; a redirect needs only verb+path translation.
- **DIVERGENT** — edge-api has a near-equivalent but the contract/behavior/auth differs materially. Needs a migration *decision*, never a blind redirect.
- **NET-NEW** — no edge-api equivalent; primary-api is the only home. Must be migrated to edge-api (or refdata-api) before primary-api can die.

> **ADR-0026 target split matters for disposition.** Writes fold → **edge-api**; reads fold → **refdata-api** (server-side `customer_id` injection is the single tenant authority). So even where edge-api *today* has a duplicate read, the strategic home for reads is refdata-api. The disposition column reflects the ADR target, not just "does edge-api have it."

---

## Classification counts

| Class | Count | Notes |
|---|---|---|
| **EXACT-DUP** | 14 | 13 write endpoints (downtimes + PO control) whose *service code is byte-identical to edge-api's* + the trivial `GET /` root |
| **DIVERGENT** | 16 | all 5 reads + users CRUD (5) + roles CRUD (5) + PO `start` (auth-guard delta) |
| **NET-NEW** | 2 | `GET /api/healthz`, `GET /api/readyz` — infra probes, no edge-api HTTP equivalent (but retire-without-migrate; orchestrator owns probes) |
| **Dead code** | 1 controller | `ProductionOrdersController` (`@Controller('production-orders')`, zero routes, no `/api` prefix) — delete freely |
| **Total routable** | 32 | + 1 dead controller |

**Premise check — "almost entirely edge-api duplicates, no distinct consumer, the cheapest retire":** **PARTIALLY HOLDS, with two material surprises** (detailed at the bottom). The *write* surface is a clean fork of edge-api (cheapest retire, as claimed). But the *read* surface + users/roles carry a **different auth model (Firebase / `MultiAuthGuard` + per-user line permissions)** that edge-api's `?token=` API-key middleware does not implement — a blind redirect would silently drop tenant/permission scoping. And several endpoints are **half-baked stubs with hardcoded `idEnterprise: 1` / `lines: [1,2]`** — broken for any real tenant, which is a *different* reason "no consumer" is plausible for them.

---

## Auth-model divergence (the load-bearing difference)

| | primary-api | edge-api |
|---|---|---|
| Global auth | **None global.** Only `RequestLoggerMiddleware` on `/api/*path`. Auth is per-controller. | Global `AuthMiddleware` on `/api/*` — rejects if `?token=` **and** `?idEnterprise=` both missing. |
| Auth mechanism | `@UseGuards(MultiAuthGuard)` on **only `users` + `production-orders/start`** → tries **Firebase Bearer** then **API-key**. Other controllers read `req.headers.enterprise \|\| req.query.idEnterprise` + a `token` header, unguarded at the framework level. | `?token=` API key + `?idEnterprise=` query, uniformly. |
| Tenant / permission scope | Reads reference `userPermissions.lines` (per-user line ACL) — but it is **hardcoded** (`{ lines: [1,2] }`, `idEnterprise: 1`) with `// TODO: extract from token`. Users/roles pull `req.user.idEnterprise` (Firebase) / `req.headers.uid`. | `idEnterprise` from query; no per-user line ACL. |
| DB access | **Prisma** (`PrismaService.$queryRaw`). | **pg-promise** DAOs (`PostgresAdapter`, `UnityOfWork`). |
| Audit trail | `res.locals.logData: UserLogsDTO` — **same shape** `{ eventType, payload, lineId, enterpriseId }`. | identical convention. |

The shared `UserLogsDTO` shape and **byte-identical PO/downtime service code** (e.g. both `start-production-order.service.ts` throw `'Production order already running'` at line 20) confirm primary-api's write surface was **forked from edge-api**. That is why the writes are clean EXACT-DUPs.

---

## Full retirement table

Legend — **Disposition:** `redirect→edge-api:X` (caller-migrate to edge path X; verb/path translation only) · `migrate-then-retire→refdata-api` (read; rebuild in refdata-api per ADR-0026) · `decision-needed` (auth/shape delta must be resolved first) · `delete` (dead/infra, no migration). **Gated?** = blocked on the access-log "live caller?" evidence before executing.

### Writes — downtimes (EXACT-DUP; forked service code)

| # | primary-api route | Class | edge-api target | Disposition | Risk | Caller-evidence gate |
|---|---|---|---|---|---|---|
| 1 | `POST /api/downtimes/manual` | EXACT-DUP | `POST /api/downtimes/create-manual-event` | redirect→edge-api | Low — verb same (POST), path rename | **Gated** |
| 2 | `DELETE /api/downtimes/manual` | EXACT-DUP | `POST /api/downtimes/delete-manual-event` | redirect→edge-api | Low-Med — **DELETE→POST verb change**; browser CORS on edge-api allows only GET/POST so this is actually *required* | **Gated** |
| 3 | `PATCH /api/downtimes/manual/:id` | EXACT-DUP | `POST /api/downtimes/edit-manual-event` | redirect→edge-api | Low-Med — **PATCH→POST**; `:id` path-param → body field | **Gated** |
| 4 | `POST /api/downtimes/manual/split` | EXACT-DUP | `POST /api/downtimes/split-manual-downtime` | redirect→edge-api | Low | **Gated** |
| 5 | `POST /api/downtimes/split` | EXACT-DUP | `POST /api/downtimes/split` (same path) | redirect→edge-api | Low — identical path | **Gated** |
| 6 | `PATCH /api/downtimes/:id` (justify) | EXACT-DUP | `POST /api/downtimes/justify` | redirect→edge-api | Low-Med — **PATCH→POST**; `:id` → body | **Gated** |

### Writes — production-orders (EXACT-DUP; forked service code)

| # | primary-api route | Class | edge-api target | Disposition | Risk | Caller-evidence gate |
|---|---|---|---|---|---|---|
| 7 | `POST /api/production-orders/create` | EXACT-DUP | `POST /api/production-orders/create` | redirect→edge-api | Low — identical | **Gated** |
| 8 | `POST /api/production-orders/create-and-start` | EXACT-DUP | same | redirect→edge-api | Low | **Gated** |
| 9 | `POST /api/production-orders/setup` | EXACT-DUP | same | redirect→edge-api | Low | **Gated** |
| 10 | `POST /api/production-orders/replace` | EXACT-DUP | same | redirect→edge-api | Low | **Gated** |
| 11 | `POST /api/production-orders/stop` | EXACT-DUP | same | redirect→edge-api | Low | **Gated** |
| 12 | `POST /api/production-orders/change-status` | EXACT-DUP | same | redirect→edge-api | Low | **Gated** |
| 13 | `POST /api/production-orders/change-time` | EXACT-DUP | same | redirect→edge-api | Low | **Gated** |
| 14 | `POST /api/production-orders/start` | **DIVERGENT** (auth only) | `POST /api/production-orders/start` | decision-needed → then redirect→edge-api | **Med** — business logic identical, but primary-api guards with `MultiAuthGuard` (accepts **Firebase Bearer**); edge-api takes `?token=`. Front4 callers sending a Firebase token will not authenticate against edge-api as-is. Also: ADR-0026 notes edge-api `start` will gain the **#32 staleness gate** — confirm parity direction. | **Gated** |

### Reads (DIVERGENT — target refdata-api per ADR-0026)

| # | primary-api route | Class | edge-api equiv (today) | Disposition | Risk | Caller-evidence gate |
|---|---|---|---|---|---|---|
| 15 | `GET /api/downtimes/pending` | DIVERGENT | `GET /api/downtimes/pending` | migrate-then-retire→refdata-api | **Med** — primary-api adds `page/limit/interval` pagination + `{data,page,results}` envelope + (stubbed) per-user line ACL / `ForbiddenException`. Shapes differ from edge-api. Reads belong in refdata-api. | **Gated** |
| 16 | `GET /api/downtimes/justified` | DIVERGENT | `GET /api/downtimes/justified` | migrate-then-retire→refdata-api | **Med** — UNION of `equipment_events` + `equipment_events_man`; pagination envelope; stubbed ACL. | **Gated** |
| 17 | `GET /api/equipments` | DIVERGENT | `GET /api/equipments` | migrate-then-retire→refdata-api | **Med** — **hardcoded** `userPermissions {lines:[1,2], uid:'123', idEnterprise:1}`. Broken for tenant≠1. | **Gated** (likely no real consumer — see surprises) |
| 18 | `GET /api/equipments/:id/reasons` | DIVERGENT | `GET /api/equipments/:id/reasons` | migrate-then-retire→refdata-api | **Med** — **hardcoded** `{lines:[1..5], idEnterprise:1}`. | **Gated** |
| 19 | `GET /api/pages` | DIVERGENT (verify-shape) | `GET /api/pages` | migrate-then-retire→refdata-api | Low-Med — both "pages for enterprise"; edge-api resolves `idEnterprise` from query + emits `logData`; primary-api reads `headers.enterprise \|\| query.idEnterprise`. Compare response DTO before treating as EXACT-DUP. | **Gated** |

### Users CRUD (DIVERGENT — Firebase-bound; edge-api has capability but different auth/verbs)

| # | primary-api route | Class | edge-api equiv | Disposition | Risk | Caller-evidence gate |
|---|---|---|---|---|---|---|
| 20 | `POST /api/users` | DIVERGENT | `POST /api/users/create` | decision-needed | **Med** — both provision a Firebase auth user, but primary-api derives `idEnterprise` from `req.user` (Firebase token via `MultiAuthGuard`); edge-api takes `idEnterprise` in the DTO body + scrubs Firebase fields from the audit log. Tenant source differs. | **Gated** |
| 21 | `GET /api/users` | DIVERGENT | `GET /api/users` | decision-needed | Med — `req.user.idEnterprise` vs `?idEnterprise=`. | **Gated** |
| 22 | `GET /api/users/:id` | DIVERGENT | `GET /api/users/:id` | decision-needed | Med — same auth-source delta. | **Gated** |
| 23 | `PATCH /api/users/:id` | DIVERGENT | `POST /api/users/edit` | decision-needed | Med — verb + auth-source. | **Gated** |
| 24 | `DELETE /api/users/:id` | DIVERGENT | `POST /api/users/delete` | decision-needed | Med — verb + auth-source. | **Gated** |

### Roles CRUD (DIVERGENT — path `roles` vs edge `user-roles`; one stub)

| # | primary-api route | Class | edge-api equiv | Disposition | Risk | Caller-evidence gate |
|---|---|---|---|---|---|---|
| 25 | `POST /api/roles` | DIVERGENT | `POST /api/user-roles/create` | decision-needed | Med — path domain differs (`roles`↔`user-roles`); confirm role/permission model parity. | **Gated** |
| 26 | `GET /api/roles` | DIVERGENT | `GET /api/user-roles` | decision-needed | Med — primary-api scopes by **Firebase `uid` header** + enterprise. | **Gated** |
| 27 | `GET /api/roles/:id` | DIVERGENT (**stub**) | `GET /api/user-roles/:id` | delete (or migrate) | Low — primary-api returns **501 Not Implemented**. No behavior to preserve. | **Gated** (probably safe to drop) |
| 28 | `PATCH /api/roles/:id` | DIVERGENT | `POST /api/user-roles/edit` | decision-needed | Med — verb + path. | **Gated** |
| 29 | `DELETE /api/roles/:id` | DIVERGENT | `POST /api/user-roles/delete` | decision-needed | Med — verb + path; guards ("cannot remove Super User / role with users assigned") must exist in edge-api too. | **Gated** |

### Infra / dead (NET-NEW-infra + dead code)

| # | primary-api route | Class | edge-api equiv | Disposition | Risk | Caller-evidence gate |
|---|---|---|---|---|---|---|
| 30 | `GET /api/healthz` | NET-NEW (infra) | none (edge-api has bare `GET /`) | delete (no migrate) | Low — k8s/EB probes are orchestrator-owned; retarget the deployment probe, don't port the route. | Not gated (infra) |
| 31 | `GET /api/readyz` | NET-NEW (infra) | none | delete (no migrate) | Low — same. | Not gated (infra) |
| 32 | `GET /` (app root) | EXACT-DUP | `GET /` | delete | Low — trivial liveness string. | Not gated |
| — | `ProductionOrdersController` (empty) | dead code | n/a | delete | None — registers zero routes. | Not gated |

---

## Ordered execution plan (after caller-evidence lands)

1. **Delete-first the free wins** (no consumer possible / dead): `ProductionOrdersController` (dead), `GET /` , `roles/:id` 501 stub. Retarget deploy probes off `healthz/readyz`, then drop them.
2. **Confirm "no live caller" per row** from the access-log evidence. Any row with **zero** callers over the frozen window → retire directly (skip the redirect/façade). This is where the "no distinct consumer" premise pays off — if the writes truly have no callers (front4 may already hit edge-api directly), the 13 EXACT-DUP writes retire with near-zero work.
3. **For write rows WITH callers** (#1-13): stand up same-shape **façade** endpoints on the primary-api host that translate verb+path and forward to edge-api (or issue 308 redirects where the client follows them), migrate callers, then remove. Verb changes (DELETE/PATCH→POST) mean a 308 alone won't work for browser clients — prefer caller-migration or a forwarding façade.
4. **PO `start` (#14):** resolve the **Firebase-token auth gap** first (edge-api must accept the front4 Firebase token, or front4 must switch to `?token=`), and confirm the #32 staleness-gate direction, before migrating.
5. **Reads (#15-19):** do **not** point at edge-api. Build/verify the equivalent in **refdata-api** with real per-tenant `customer_id` injection (replacing the hardcoded stubs), parity-check response shape per consumer, then retire.
6. **Users/roles (#20-29):** design decision with tech-lead — reconcile the Firebase-`req.user` tenant source vs edge-api's `idEnterprise`-in-body, and the `roles`↔`user-roles` naming. These are the highest-effort rows.
7. **Final:** 30-day frozen-read window (endgame decommission discipline), then remove primary-api.

---

## Honest premise verdict + surprises

**"All dups, no consumer, cheapest retire" — PARTIALLY TRUE.**

- ✅ **Holds for the write surface (13 endpoints).** Byte-identical forked service code. If the access log shows no callers (plausible — front4 may already write to edge-api), these are indeed the cheapest retire in the whole ADR-0026 program.
- ✅ **No net-new *business* capability.** The only NET-NEW routes are infra probes (`healthz`/`readyz`). Nothing in primary-api is a unique feature edge-api lacks.

**Surprise 1 — the auth model is NOT the same.** primary-api's users/roles/PO-start use **Firebase Bearer via `MultiAuthGuard`** and per-user context (`req.user`, `uid` header); edge-api uses a flat `?token=`+`idEnterprise` API key with no per-user permissions. A blind redirect of these rows would **silently drop the Firebase-user identity and any (intended) per-line ACL**. These are DIVERGENT, not EXACT-DUP — they need a real migration decision. This is the single biggest landmine in the "just redirect it" story.

**Surprise 2 — the read + reasons endpoints are half-baked stubs with hardcoded tenant scope.** `get-downtimes`, `equipments`, and `get-reasons` all hardcode `userPermissions`/`idEnterprise` (`{lines:[1,2]}`, `idEnterprise:1`, `// TODO: extract from token`). They are **broken for any tenant ≠ 1** and violate the standing *no-hardcoded-enterprise-id* directive. Practically: "no distinct consumer" is likely true for these — but because they're **too broken to have shipped to real tenants**, not because edge-api serves them. **Flag to tech-lead/security:** if any of these *are* reachable in staging/prod with a valid token, they are a cross-tenant data-exposure risk (they'd serve enterprise-1 / lines-1,2 data to whoever calls). This aligns with the ADR-0026 note that "security fixes (#30/#52) are stopgaps on these retiring services."

**For a senior reviewer to double-check:**
- `GET /api/pages` (#19) — I classified DIVERGENT conservatively (didn't diff the response DTO field-by-field). If shapes match it may be a clean EXACT-DUP read → drops migration cost.
- The Firebase-auth rows assume front4 sends a Firebase Bearer to primary-api today. Confirm from the access-log evidence which auth header real callers actually use — that decides whether the auth gap is real or theoretical.
- Whether edge-api's `user-roles` service enforces the same invariants primary-api's roles service documents ("cannot remove Super User", "cannot remove role with users assigned") — parity check before retiring #29.
