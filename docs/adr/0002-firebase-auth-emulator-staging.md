# ADR 0002 — Firebase Auth Emulator for staging↔prod auth parity

**Status:** Proposed
**Date:** 2026-06-29
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team

---

## Context

### The parity gap

Prod's operator login flow goes through real Firebase Auth:

```
operator SPA --POST creds--> edge-node-red /session
                                    │
                                    ├──> https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword
                                    │       ↳ returns Firebase ID token + refresh token + UID
                                    ├──> looks up user in postgres by id_user_firebase
                                    └──> returns JWT to operator SPA
```

Staging today **doesn't use Firebase at all** — it's a bypass:

```yaml
# compose.staging.yml
edge-nodered:
  environment:
    FIREBASE_API_KEY: bypassed-by-hasura-admin-secret
    HASURA_ADMIN_SECRET: ${HASURA_GRAPHQL_ADMIN_SECRET}
```

```python
# edge-node-red/transform_flows.py — injected at build time
NEW_HEADER = (
    "...(env.get('HASURA_ADMIN_SECRET')\n"
    "            ? { 'X-Hasura-Admin-Secret': env.get('HASURA_ADMIN_SECRET') }\n"
    "            : { 'Authorization': 'Bearer ' + flow.get('idToken') })"
)
```

The function-node bypass swaps `Authorization: Bearer <idToken>` for `X-Hasura-Admin-Secret` whenever the admin secret env var is set. The HTTP request nodes still nominally call out to `identitytoolkit.googleapis.com`, but with a fake API key — those calls fail silently and the bypass-based auth chain takes over.

**Concretely, this means:** if a developer changes prod's `/session` flow (token refresh, custom claims, Firebase UID lookup logic), there is **no way to test that change on staging** before shipping to prod. Bugs in Firebase-specific code paths surface only after the prod deploy.

### Why this matters now

Several recent debugging sessions have shown how much friction the staging-vs-prod gap creates. Auth is currently the worst-aligned subsystem: every other major piece (DB schema, OEE triggers, mirror-worker replay) has been brought to parity over the last two months, but auth has been left behind because "Firebase costs money + needs a real Google project."

The **Firebase Auth Emulator** removes that constraint: it speaks the real Firebase REST API (same endpoints, same token shapes, same error codes), runs locally in a Docker container, costs nothing, and is the official Google-supported tool for exactly this scenario.

---

## Decision

Adopt the **Firebase Auth Emulator** as the staging auth backend. Wire `edge-node-red` to route Firebase REST calls to the emulator container instead of Google's production endpoints. Remove the `HASURA_ADMIN_SECRET` bypass on staging once the emulator path is verified.

### Why the emulator over the alternatives

| Option | Cost | Parity | Vendor lock-in | Why not chosen |
|---|---|---|---|---|
| **Firebase Auth Emulator** (this ADR) | $0 ongoing | ~95% (emulates REST API; some advanced features stubbed) | None | ✅ chosen |
| Separate staging Firebase project | $0 on Spark tier until 50k MAU; paid above | 100% | Yes (Google) | Adds real external dependency + secrets to staging; 100% parity not worth the operational cost |
| Keep `HASURA_ADMIN_SECRET` bypass; document the gap | $0 | 0% | No | Honest about the gap but doesn't solve it; the parity drift compounds over time |
| Replace Firebase with Authentik on both staging + prod | $0 | N/A (changes prod too) | No | Much bigger scope; out of band for this ADR |

The ~5% emulator gap (some advanced features like SMS auth, OIDC providers, App Check are stubbed) doesn't affect our flow — we only use email/password + ID token issuance + refresh.

---

## Implementation plan

### File-by-file changes

**Repo: `edge-node-red` (submodule)**

| File | Change | Risk |
|---|---|---|
| `transform_flows.py` | New `fix_firebase_host(url)` function that replaces hardcoded `https://identitytoolkit.googleapis.com` and `https://securetoken.googleapis.com` with `$(FIREBASE_AUTH_HOST)` and `$(FIREBASE_TOKEN_HOST)` env-var refs. Modify `fix_hasura_func` to make the `HASURA_ADMIN_SECRET` bypass conditional on `FIREBASE_AUTH_HOST` NOT being set (so staging-with-emulator uses real Firebase code path; dev-without-emulator keeps the bypass). | Low |
| `flows.json` | Two `http request` nodes updated by `transform_flows.py` re-run | Low (regenerated, not hand-edited) |
| `flows/GraphQL.json` | Same — two `http request` nodes updated | Low |
| `.env.example` | Document `FIREBASE_AUTH_HOST` (default empty = use real Google) and `FIREBASE_TOKEN_HOST` env vars | Trivial |
| `Dockerfile` | No change — transform_flows.py runs at build time | — |

**Repo: `packiot-stack-alpha` (parent)**

| File | Change | Risk |
|---|---|---|
| `compose.staging.yml` | Add `firebase-auth-emulator` service (static IP 172.18.0.30, port 9099 exposed only on `127.0.0.1:9099`, healthcheck, volume for state). Update `edge-nodered` env: add `FIREBASE_AUTH_HOST=http://firebase-auth-emulator:9099/identitytoolkit.googleapis.com`, `FIREBASE_TOKEN_HOST=http://firebase-auth-emulator:9099/securetoken.googleapis.com`. Remove `HASURA_ADMIN_SECRET` from `edge-nodered` env (only for that service; Hasura itself keeps using it). Add `firebase-auth-emulator:172.18.0.30` to `extra_hosts`. Add `firebase-auth-emulator` to `depends_on`. | Medium (the bypass-removal is the risky bit) |
| `terraform/staging/scripts/seed-firebase-users.sh` (new) | Curl the emulator REST API to create test users: `dev.cpack@packiot` / `packiot`. Idempotent (delete-then-create or check-then-create). | Low |
| `db/seed-firebase-uid-staging.sql` (new) | Ensure the `users` table on staging has rows with `id_user_firebase` matching the emulator-issued UIDs for the seeded users. Idempotent (`INSERT ... ON CONFLICT DO UPDATE`). | Low |
| `Makefile` | Add `staging-seed-firebase` target that runs the seeding script + SQL | Trivial |

**Staging DB (manual one-time, captured in seed SQL above)**

- Run the seed SQL once after the emulator is up + has issued the deterministic UID for the seeded user.
- Subsequent deploys re-run the seeds idempotently via `db-migrate` service.

### Sequencing — 4 PRs

Each PR is independently shippable; staging stays functional throughout.

| # | PR | Change | Validates |
|---|---|---|---|
| **1** | `edge-node-red`: parameterize Firebase host env vars | `transform_flows.py` + flows JSON. Defaults preserve prod behavior (empty env var → original Google URLs). | No behavior change in prod or staging yet |
| **2** | `packiot-stack-alpha`: add emulator container + seed script (HASURA_ADMIN_SECRET bypass still active) | New `firebase-auth-emulator` service in compose.staging.yml + scripts. Existing auth flow unchanged (bypass still wins). | Emulator container starts, responds to `curl localhost:9099`, seeded user exists |
| **3** | `edge-node-red`: bypass becomes conditional on FIREBASE_AUTH_HOST | Modify `fix_hasura_func` in `transform_flows.py` so the bypass header is only injected when `FIREBASE_AUTH_HOST` is empty. | In dev (no `FIREBASE_AUTH_HOST`): bypass still works. In staging (env set): real Firebase code path activates. |
| **4** | `packiot-stack-alpha`: bump edge-node-red submodule + run DB seed | Bring PR 3's behavior into the staging deploy. | Operator login on staging goes through emulator end-to-end |

### Test plan

After **PR 2** deploys:
- [ ] `curl http://127.0.0.1:9099/` on the staging app EC2 returns Firebase emulator UI
- [ ] `curl -X POST 'http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=any' -d '{"email":"dev.cpack@packiot","password":"packiot","returnSecureToken":true}'` returns a valid idToken
- [ ] Emulator container is `healthy` in `docker ps`
- [ ] Operator login on staging still works (via bypass — emulator not yet wired in)

After **PR 4** deploys:
- [ ] Operator login on staging as `dev.cpack / packiot` succeeds
- [ ] edge-nodered logs show HTTP POST to `firebase-auth-emulator:9099/...` (not `identitytoolkit.googleapis.com`)
- [ ] Operator can fetch `/production`, `/pending-events`, `/solved-events` (auth chain intact)
- [ ] Operator can submit actions (justify, change PO, etc.) → mirror-worker picks them up in user_logs and replays to … wait, mirror reads PROD's user_logs, not staging's. Strike — irrelevant.
- [ ] No `X-Hasura-Admin-Secret` headers in flow logs (bypass deactivated)
- [ ] Token refresh fires after 15 min (the locked-in staging TTL) and operator stays logged in transparently — verifiable by leaving a staging session open for ~20 min and watching edge-nodered logs for a POST to `securetoken.googleapis.com` path on the emulator

### Rollback

If anything in PR 4 breaks the operator login flow:

```bash
gh pr revert <PR4-number>          # one-command revert
```

This re-enables the `HASURA_ADMIN_SECRET` bypass via the submodule pointer rollback. Staging login returns to current behavior within the auto-deploy cycle (~5 min).

PRs 1–3 are non-breaking by design — they can stay merged.

---

## Resolved decisions (locked in 2026-06-29)

All six original open questions have been answered during the design conversation. Recorded here as decisions the implementer should treat as load-bearing, not optional re-litigation points.

1. **Canonical test-user list.** ✅ **Just `dev.cpack`** (single user, single role). Per-role permission-flow testing is out of scope; staging is for verifying the auth *mechanism*, not exercising the full RBAC matrix.
2. **Deterministic UID seeding.** ✅ **Approach B — Firebase Admin SDK with an explicit constant UID.** Seed script calls `admin.auth().createUser({ uid: 'staging-dev-cpack-uid', email: 'dev.cpack@packiot', password: 'packiot' })`. The same constant `staging-dev-cpack-uid` appears in both the seed script and the SQL seed for the `users.id_user_firebase` column. No capture step, no timing dependency, survives any restart.
3. **Emulator persistence.** ✅ **No persistence.** Re-seed on every container startup via the seeding script run in `depends_on`. Predictable, identical-across-deploys auth state. The cost — every container restart logs operators out — is acceptable for staging (deploys are infrequent and re-login is cheap). Persistence would be the wrong default because the value of staging is *reproducibility*, not *accreted state*.
4. **`FIREBASE_API_KEY` value in staging.** ✅ **`staging-emulator-key`** (any non-empty, non-prod string). The emulator accepts any key in the query param — this value exists only to make logs + grep readable and to prevent accidental cross-talk if the URL ever leaks to a real Firebase endpoint.
5. **Operator app reach-throughs.** ✅ **No operator-side changes.** Verified during scoping: the API key the operator SPA sends to `/session` is the *user's password*, not the Firebase API key. Operator code path is unchanged.
6. **Token TTLs.** ✅ **Permanent 15-minute TTL on the staging emulator.** Configured via the emulator's `--token-ttl` flag (verify exact name during implementation). Turns every operator session into an implicit refresh-flow test: any bug in the refresh code path surfaces within ~15 minutes of use, with no deliberate testing required. Diverges from prod's 1h value but the *mechanism* is identical — refresh-on-expiry — and that's what we're testing.

---

## Risks

| Risk | Probability | Severity | Mitigation |
|---|---|---|---|
| PR 4 deploy breaks operator login on staging | Medium | Medium (staging only, not customer-facing) | Sequenced PRs; PR 4 is one revert command from rollback |
| Emulator behavior diverges from real Firebase in a subtle way that masks a real prod bug | Low | Medium | Test the specific flow we depend on (signInWithPassword + token refresh + idToken validation) end-to-end on staging before relying on the emulator for QA |
| Container resource cost on staging app EC2 | Low | Low | Auth emulator is tiny (~50MB RAM); fits comfortably on the existing instance |
| Seeded test users drift from prod schema (`users` table additions) | Low | Low | DB seed SQL is idempotent; re-runs on every `db-migrate` invocation |

---

## References

- [Firebase Auth Emulator docs](https://firebase.google.com/docs/emulator-suite/connect_auth) — official Google guide
- [Firebase Local Emulator Suite overview](https://firebase.google.com/docs/emulator-suite) — for context on what's emulated
- [andreysenov/firebase-tools Docker image](https://hub.docker.com/r/andreysenov/firebase-tools) — community-maintained Docker image for the firebase-tools CLI (alternative to building our own)
- Internal: `edge-node-red/transform_flows.py` — current bypass implementation
- Internal: `[[ADR 0001]]` — parent ADR introducing the document convention this one follows
