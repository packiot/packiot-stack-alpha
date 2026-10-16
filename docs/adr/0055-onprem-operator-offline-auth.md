# ADR-0055 — On-prem operator offline auth (cached token + local JWKS)

- **Status:** Accepted (design) — 2026-09-03
- **Builds on:** ADR-0034 (Firebase→Cognito), ADR-0054 (on-prem edge / operator-edge), the 2026-09-03 operator + front4 Cognito-only cutover.
- **Decision owner:** user (chose "cached token + local JWKS", 2026-09-03).

## Context

Auth is now **Cognito, always Cognito**. The cloud operator authenticates via
Cognito SRP and carries the Cognito **ID token** as the Bearer; edge-api/refdata
verify it (RS256 against the pool JWKS). The cloud verifier
(`services/read-api/cmd/refdata-api/auth_cognito.go`) fetches the pool JWKS over
the network and caches it **in memory** (TTL + refresh-on-unknown-kid).

The **on-prem operator** (operator-edge, ADR-0054) runs on the factory box for
outage resilience — it must keep working when the box **has no internet**. But
Cognito lives in the cloud: with no network the box can neither run an SRP
sign-in nor fetch the JWKS, so a naive Cognito-only operator would be unusable
during exactly the outage it exists to survive.

Note (2026-09-03): the on-prem stack today (`compose.onprem-edge.yml`) is the
read-only fat-edge dashboard set (mosquitto, sparkplug-agent, edge-transformer
`LOCAL_DECODE_ONLY`, edge-dashboard) — there is **no** on-prem operator or local
auth backend yet. This ADR is the design to implement **when operator-edge is
deployed on the box**; it does not describe running code.

## Decision

**Cached token + local JWKS.** The box caches everything the token check needs so
an *already-authenticated* operator continues to work offline:

- **When ONLINE:** the operator signs in via Cognito (through the cloud) as usual.
  The on-prem operator-backend (a small local verify shim, the box twin of the
  refdata verifier) **persists the pool JWKS to disk** and keeps it fresh; the
  operator SPA holds its Cognito ID + refresh tokens (Amplify, as in the cloud).
- **When OFFLINE:** the local backend validates the operator's cached Cognito ID
  token **against the disk JWKS** (RS256, iss/aud/exp) with **zero network**.
  Reads are served from the local live-state cache (edge-dashboard/localstate);
  writes queue in the ADR-0054 outbox and drain when connectivity returns.

### Offline window (accepted tradeoff)

The offline session is bounded by the **ID token TTL (1 h)**. Amplify's refresh
token (30 d) can mint a fresh ID token, but **refresh requires Cognito** — so a
*fresh login* or a *token refresh* cannot happen offline. The box therefore
supports **continuing** an existing session through an outage up to the token's
remaining validity, not starting a new one mid-outage. The user accepted this
(2026-09-03); it is the simplest option and stores **no password at rest**. If
long-outage fresh logins are ever required, revisit with a local password
verifier (a break-glass account) as a follow-up — explicitly out of scope here.

## Mechanism (what to build)

1. **Disk-persistent JWKS cache.** Extend the existing `jwksCache`
   (`auth_cognito.go`) with an optional on-disk seam: on a successful online
   fetch, atomically write the JWK set (the public `{kid,n,e}` entries) to
   `JWKS_CACHE_FILE`; on startup with no network, **load from that file** instead
   of failing. The JWKS is **public key material** — safe to persist at rest. Keep
   the in-memory RWMutex single-flight refresh; disk is only the cold-start /
   offline source. Reusable by any box-side verifier.
2. **On-prem operator-backend (verify shim).** A minimal local service (or a mode
   of the box's read shim) that RS256-verifies the operator's Cognito Bearer using
   the disk-cached JWKS and resolves the operator's scope from the box's local
   copy of the entity/register data. Mirrors edge-api `/session`'s Cognito verify,
   minus the cloud DB (uses the box's cached descriptor/register).
3. **Token caching** is already handled by Amplify on the SPA side (ID + refresh
   in its storage); nothing extra to persist server-side beyond the JWKS.

## Onboarding wiring (everything on-prem via csadmin)

The on-prem operator deploy (csadmin onboarding, the ADR-0054 generator) must
provision:
- the JWKS cache file path + a first **online** JWKS warm-fetch so the box has a
  valid cache before its first outage;
- `COGNITO_ISSUER` / `COGNITO_CLIENT_ID` (public) for the local verifier;
- the local verify shim in `compose.onprem-edge.yml`, alongside the operator-edge
  service and the existing outbox (ADR-0054).

## Security posture

- **JWKS at rest = public keys** — no secret exposure. Never persist tokens
  server-side; the SPA holds them (memory/Amplify storage), same as cloud.
- **No password at rest** on the box (the reason this option was chosen over a
  local verifier).
- **Fail-closed** when the disk JWKS is absent/expired-beyond-grace and there is
  no network: deny (the operator must have been online at least once to seed the
  cache — the warm-fetch above guarantees it at onboarding).
- Writes remain gated by the ADR-0054 outbox + idempotency; offline auth never
  loosens the write path, only lets an authenticated operator reach it.

## Consequences

- The box can run the operator through an outage up to token TTL with zero cloud
  dependency, using only public key material cached locally.
- Build is **gated on operator-edge being deployed** (ADR-0054 remainder). Until
  then this is design-only; the disk-JWKS extension can land independently (it is
  a harmless, opt-in seam on the existing verifier).
- Follow-up (explicitly deferred): break-glass local password verifier for
  fresh offline logins beyond token TTL.
