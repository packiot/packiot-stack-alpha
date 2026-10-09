# Plan — `operator_pw_hash` retirement (task #159, operator-password slice)

**Status:** DONE on staging (2026-09-06) — architect chose **REMOVE**. edge-api
retirement deployed (#1121); csadmin UI field removed (staging); DB column dropped
from packiot_analytics (7 dead hashes discarded, 0 remaining); read-api comments +
ADR-0054 bcrypt-fallback superseded. **Prod:** repeat the column drop on the prod
DB after the prod edge-api/csadmin carry these commits.
**Scope:** staging first (new stack), then prod.

## TL;DR

`users.operator_pw_hash` (bcrypt) is **write-only in the current codebase** — the
cloud `/session` login is Cognito-only and **nothing verifies the hash** (the only
`bcrypt.compare` is in a unit test). BUT it is **architecturally reserved** by
ADR-0054 as the on-prem edge-operator's factory-local bcrypt `/session` fallback
for a *fresh* operator login during a connectivity outage — a case the shipped
cached-token + local-JWKS offline auth (#158) cannot serve (no network to mint a
new Cognito token).

So this is a **fork**, not a cleanup:
- **KEEP** — operator_pw_hash stays as the ADR-0054 offline fresh-login credential.
  Action is tiny: fix a stale comment. #159's "operator_pw_hash removable" premise
  is retired as incorrect.
- **REMOVE** — the platform commits to cached-token-only offline auth (accepts NO
  fresh offline login). Then retire the write path + UI + column (steps below).

**Recommendation: KEEP** unless the architect explicitly drops the ADR-0054
fresh-offline-login capability. It is inert today (write-only, no auth reader), so
it carries no security/behaviour risk by remaining; removing it forecloses a
documented outage-resilience feature for near-zero benefit.

## Current surface (verified 2026-09-06)

Writers / carriers (edge-api, `packiot-stack-alpha/edge-api/src`):
- `usecases/users/set-operator-password/*` — the set-operator-password usecase
  (controller/service/dto/module) → `users-dao.ts:147 UPDATE users SET operator_pw_hash=$1`.
- `usecases/cognito-users/shared/cognito-users.service.ts:237-239` — bcrypt-hashes
  `operatorPassword` → `cognito-users-dao.ts:28,33 INSERT ... operator_pw_hash`.
- `usecases/cognito-users/create-cognito-user/dto/create-cognito-user.dto.ts:65-66`
  and `usecases/users/create-user/dto/create-user.dto.ts:40` — the `operatorPassword`
  input field.
- `data/DAO/session/session-dao.ts:14` — SELECTs `operator_pw_hash` (DEAD read —
  login.service never uses it).
- `usecases/session/login/login.service.ts:20` — comment correctly states the
  bcrypt login path is RETIRED (accurate; no change needed). The residual is that
  `session-dao.ts` still SELECTs the (now unused-by-login) column — a harmless dead
  read that the ADR-0054 on-prem bcrypt login would re-use if implemented.

Consumers (UI):
- csadmin `src/pages/cognito-users.tsx` (operator-password field, sends
  `operatorPassword`) + `src/api/users-admin.ts` (the typed field). LIVE — a CS
  engineer can set an operator password today (which currently does nothing for
  cloud auth).
- front4 only references "the separate set-operator-password endpoint" in comments.

No auth reader: `grep bcrypt.compare` → only `set-operator-password.service.spec.ts`.

## If REMOVE — coordinated retirement (ordered; each step reversible)

Contract note: edge-api DTOs use `whitelist:true`, so an old csadmin that still
sends `operatorPassword` after the field is removed gets it silently stripped (no
400). So edge-api-first is backward-compatible; csadmin cleanup can follow.

1. **edge-api (stop writing + reading), one PR:**
   - Delete the `set-operator-password` usecase (controller/service/dto/module +
     spec) and unregister it from its module.
   - Remove `operatorPassword` from create-user + create-cognito-user DTOs; remove
     the bcrypt hashing in `cognito-users.service.ts`; drop `operator_pw_hash` from
     the cognito-users-dao INSERT and users-dao UPDATE.
   - Drop `operator_pw_hash` from the session-dao SELECT.
   - Fix the login.service.ts comment.
   - Remove `bcryptjs` if it has no other user (verify first).
   - Deploy. Verify user create + cognito-user create still 2xx; login unaffected.
2. **csadmin (remove the UI), one PR:** delete the operator-password field from
   `cognito-users.tsx` and the `operatorPassword` field from `users-admin.ts`.
   Deploy. Verify user creation still works.
3. **DB migration (AFTER 1 is deployed — no writer references the column):**
   `ALTER TABLE users DROP COLUMN operator_pw_hash;` (staging; then prod). Codify
   under `db/migrations/`. Idempotent guard (`IF EXISTS`).
4. **read-api:** update the two `datasets.go` comments that mention "users minus
   operator_pw_hash" (the exclusion becomes moot; read-api already never selects it).
5. **Docs:** mark ADR-0054's bcrypt-fallback section superseded (offline auth is
   cached-token + local-JWKS only); note the fresh-offline-login case is now
   unsupported.

Pre-flight before REMOVE: confirm with the architect that no factory requires a
fresh offline operator login (ADR-0054 §outage). If any does, do NOT remove.

## If KEEP (recommended)

- Fix `login.service.ts:20` stale comment (bcrypt path is retired from cloud login;
  operator_pw_hash is reserved for the ADR-0054 on-prem fresh-offline-login only).
- Re-scope task #159: the auth dual-path FLAGS are the removable part once prod is
  Cognito-only (Firebase still prod-live — blocked); operator_pw_hash is NOT a dead
  flag, it is a reserved on-prem credential. Close the "operator_pw_hash removable"
  premise as incorrect.
