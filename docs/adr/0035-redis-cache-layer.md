# ADR-0035 — Redis application cache + refdata-api cache-aside layer

**Status:** Proposed · **Date:** 2026-07-22 · **Scope:** `compose.staging.yml` (new `app-redis` service) · `services/refdata-api` (new `internal/cache` package + a hook in the `/v1/query` dataset dispatch) — **STAGING, additive, flag-gated, reversible.** No prod change. **Decision owner:** platform engineer / tech-lead — pending USER sign-off on §9 (prod ElastiCache) and §10 (count-engine follow-up).

**Builds on / honors:**
- [ADR-0027](0027-refdata-api-surface-1-read-contract.md) — the **single tenant-injection authority** invariant (`credential → customer_id → $1`; the client never names a tenant). The cache key is fenced on the SAME server-resolved `id_enterprise`; the cache never trusts a client-supplied tenant.
- [ADR-0032](0032-collapse-to-single-flow-f3.md) — the F1↔F3 read-plane flow switch. The cache key includes the active flow so a Redis shared across flow deployments cannot alias F1 and F3 results.
- [ADR-0015](0015-customer-facing-query-api.md) — the composable query API / dataset registry the cache-aside wraps.

**Relates to:** the production-count review's finding that the count engine keeps per-tenant `memState` in-process (a single-writer-per-tenant gap) — the SAME Redis is the fix vehicle (§10).

---

## 1. Context — the load shape the cache is built for

front4 dashboards are **polling** clients: each open dashboard re-issues its `/v1/query` dataset reads on a refresh tick (seconds). Many browsers of the **same tenant** watching the same lines issue the **same** dataset read within the same tick, and every one of those reads currently hits the same `h_piot_*` analytics SQL on the DB. Between two 1-minute cagg refreshes the DB answer does not change — so that fan-in is almost pure waste.

A short-TTL **cache-aside** in front of the dataset dispatch collapses the fan-in to **one DB hit per `(tenant, dataset, params)` per TTL window**. The DB load drops, poll latency drops, and — because the TTL is chosen per dataset to match the backing data's own update cadence — the operator's numbers stay fresh.

This is a **read-plane optimization only**. It is additive, flag-gated, and fail-open: nothing about correctness or the served bytes depends on the cache being present.

---

## 2. Decision

1. Stand up a **dedicated application Redis** (`app-redis`, `redis:7-alpine`) on the staging compose net — **separate** from `authentik-redis` (authentik's private session/task store; never reused for app data).
2. Add a `refdata-api` **cache-aside** layer (`internal/cache`) hooked into the `/v1/query` **named-dataset** dispatch (NOT the auth path, NOT the legacy metric×dimension composer).
3. Key every entry on the **server-resolved `id_enterprise`** (+ flow + dataset + a stable hash of the compiled SQL & args). Tenant isolation is the #1 correctness requirement.
4. TTL is **per dataset**, tiered by data volatility (reference/config long, live OEE short), configured in one table in `datasets.go`.
5. Gate on `REDIS_CACHE_ENABLED` (default `true` on staging) + `REDIS_URL`. **Fail open**: any cache error serves from the DB.

---

## 3. The `app-redis` service (cache, not store)

```yaml
app-redis:
  image: redis:7-alpine
  command: redis-server --maxmemory 256mb --maxmemory-policy allkeys-lru --appendonly no --save ""
  # healthcheck: redis-cli ping ; mem_limit 320m ; own IP 172.18.0.35
```

- `--maxmemory 256mb` + `allkeys-lru` — it is a **cache**: bound the footprint and evict the coldest keys under pressure rather than OOM. `mem_limit` (320m) sits above `maxmemory` to leave Redis its own overhead headroom.
- `--appendonly no` + `--save ""` — **no persistence**. A restart is a cold cache; the read plane fails open and re-fills from the DB, so durability buys nothing here and costs I/O.
- **Non-secret** today: internal `packiot-net` only, no published port. If a password is ever needed, inject it via a secret (`--requirepass ${...}` from `.env` / Secrets Manager) — never hardcoded, same rule as every other credential in the compose.

---

## 4. Cache-aside design

The hook lives in the `/v1/query` handler (`query.go`), on the named-dataset branch only, AFTER `compileDataset` has produced the tenant-fenced SQL + args:

```
build key(cid, flow, dataset, sql, args)
GET key ──hit──▶ return cached bytes            (loader NOT run)
   │ miss / cache-error (fail-open)
   ▼
run DB query → marshal JSON array bytes         (the loader)
SET key = bytes  EX <per-dataset TTL>           (best-effort; SET error ignored)
return bytes
```

`GetOrLoad(ctx, key, ttl, loader)` is the single primitive. The DB read + JSON marshaling (`runQueryJSON`) is shared verbatim by the cached and uncached paths, so **the served bytes are byte-identical** whether cache is on or off — the cache changes only *where the bytes came from*.

The legacy metric×dimension composer path (`{"dataset"}` absent) is **never cached** — it is not a front4 poll target.

---

## 5. 🔒 Tenant-key isolation (the load-bearing invariant)

```
refdata:ds:v1:<flow>:e<id_enterprise>:<dataset>:<sha256(sql,args)[:32]>
```

- `id_enterprise` is an **explicit key segment**, not merely folded into the hash. A hash collision therefore can **never** serve one tenant's rows to another — the `e<n>` prefix differs. This is deliberate belt-and-suspenders: even though `id_enterprise` is also `args[0]` (and thus inside the hash), a leak here would be the worst possible failure, so we make it structurally impossible at the key level.
- The enterprise is the **server-resolved** `customerIDFromContext` value (ADR-0027) — the same id bound to `$1`. It is **never** taken from the request body.
- `flow` (f1/f3) is in the key because the two flows read different DBs (ADR-0032) and may return different data for the same dataset+args.
- The arg fingerprint is a SHA-256 over the domain-separated `(sql, args)`. args carry the real per-request variation (window bounds, filters, the server-derived role/equipment). Folding `sql` in means a dataset whose SQL changes across a deploy **self-busts** its old keys.

Unit test `TestDatasetKey_IncludesEnterprise` asserts that two requests identical in everything **except** the enterprise produce different keys.

---

## 6. Per-dataset TTL (freshness vs load)

TTL is set per **group** (each dataset already carries its `group`), so the ~50 dataset literals stay untouched and the freshness policy is one readable table (`datasets.go` `groupCacheTTL`). A per-dataset override wins; a negative override opts a dataset out; `0` = bypass.

| Tier | Groups | TTL | Rationale |
|------|--------|-----|-----------|
| **Reference / config** | `enterprise-config`, `settings`, `targets`, `tenant-custom` | **300 s** | Edited by CS onboarding / manual config, not the telemetry pipeline. Minutes-stale is fine; a re-polling dashboard skips the DB almost entirely. |
| **Reference (per-role bootstrap)** | `variables-context` (entities/menu per user role) | **180 s** | Slow-moving nav trees; reflects onboarding within a few minutes. |
| **Live OEE / snapshots** | `live-uns-equipment` | **15 s** | `uns_equipment_current_*` snapshots track the 1-min cagg cascade; keep near-live. |
| **Live analytics** | `oee`, `mission-control`, `overview-detail`, `downtimes-analytics`, `events-timeline`, `single-period`, `total-production`, `production-flow`, `machine-speed`, `home` | **20–30 s** | ~ the cagg cadence — collapse a burst of same-tick polls to one DB hit while the operator's numbers stay fresh. |
| **PO state** | `production-orders` | **20 s** | PO list/details flip on operator start/stop; keep short so a state change surfaces fast. |
| **default (unmapped group)** | — | **20 s** | Conservative short default. |

**Design principle:** default conservative (short). A too-short TTL merely under-caches (a correctness-safe waste); a too-long TTL on live data would show operators stale numbers (a UX bug). We bias toward freshness.

---

## 7. Fail-open

Every cache op degrades to "cache absent" on ANY error (Redis down, timeout, network):
- GET error/timeout ⇒ treated as a miss ⇒ the loader (DB) runs.
- SET error ⇒ swallowed ⇒ the already-loaded bytes are still served.
- A **loader** error is the real DB error — it is propagated (→ 500) and **never cached**.
- A misconfigured `REDIS_URL` or an unreachable Redis at boot is **non-fatal**: refdata logs and serves with a nil cache (transparent bypass). A read plane must never fail to boot because the cache is misconfigured.

Each cache op also runs under a short per-op timeout (150 ms) so a hung Redis can never dominate a request — it degrades to a miss within the budget.

---

## 8. Metrics

`refdata_cache_requests_total{result="hit|miss|error|bypass"}` on refdata's existing Prometheus default registry (the same `/metrics` the RED middleware serves). `hit`/`miss` measure effectiveness; `error` surfaces a degraded cache (fail-open in action); `bypass` counts disabled/ttl-0 pass-throughs. All four series are initialized at 0 so `rate()` reads 0, not a gap.

---

## 9. Invalidation — TTL-only for v1; write-invalidate is the future enhancement

**v1 uses TTL expiry only.** The short live-data TTLs (15–30 s) mean a write self-heals within one TTL window — good enough for the poll-heavy read shape, and it keeps the cache a pure read-side optimization with zero coupling to the write path.

**Future enhancement (NOT in this ADR):** explicit **write-through invalidation** — an edge-api write (PO start/stop, downtime justification, config edit) publishes an invalidate (a Redis `DEL` of the affected tenant's dataset keys, or a pub/sub channel refdata subscribes to). That would let the reference/config tiers run much longer TTLs without any staleness on edit. `edge-api` already has `REDIS_URL` plumbed in the compose (unconsumed) precisely so this can land without a compose change. Requires a key-tagging scheme (e.g. a per-tenant generation counter folded into the key) so an invalidate can target `(tenant, dataset)` without enumerating keys.

---

## 10. 🚩 FLAG FOR USER — two decisions this ADR surfaces

**(a) Production uses managed ElastiCache, NOT this container.** The `app-redis` container is a **staging** convenience. In production the same cache-aside points `REDIS_URL` at a managed **AWS ElastiCache (Redis)** endpoint provisioned in `api-terraform` (right-sized instance, Multi-AZ if desired, in-transit/at-rest encryption, no container to babysit). The application code is identical — only the URL (and, if encryption/auth is enabled, a password from Secrets Manager) changes. **Do not ship the container to prod.**

**(b) The same Redis fixes the count-engine `memState` gap.** The production-count review found the count engine holds per-tenant accumulator state (`memState`) **in-process** — a single-writer-per-tenant assumption that breaks the moment that engine is scaled to more than one replica (two writers → double-count, the exact class of bug ADR's two-writer-line-double-count entry documents). Moving that shared state into **this** Redis (an atomic per-tenant counter / hash) makes the accumulator a **shared** single source of truth, decoupling correctness from process count. That is a **separate follow-up** (its own ADR + task), but it is a deliberate reason to stand up a real shared Redis now rather than an ad-hoc per-service cache.

---

## 11. Consequences

- **Positive:** DB read-load relief proportional to poll fan-in; lower poll latency; a shared-state primitive the org can build on (invalidation, count `memState`, rate limiting, locks).
- **Negative / accepted:** bounded staleness up to the per-dataset TTL (chosen to be imperceptible for live data, acceptable for config); one more service to run on staging (bounded to 320 MB); a new dependency (`go-redis`, already vendored/cached).
- **Reversibility:** set `REDIS_CACHE_ENABLED=false` and redeploy → reads fall straight through to the DB; remove the `app-redis` service block → refdata fails open. Nothing else moves.

---

## 12. Rollout

1. Merge to `staging` (this PR): `app-redis` up, cache-aside ENABLED (default). Watch `refdata_cache_requests_total` hit-ratio climb and DB read-load on the analytics functions drop.
2. Validate parity: a dataset served cache-on must equal the same dataset served with `REDIS_CACHE_ENABLED=false` (byte-identical bytes; the `runQueryJSON` share guarantees this by construction).
3. Provision ElastiCache in `api-terraform` before any prod consideration (§10a).
4. Follow-ups (separate ADRs): write-through invalidation (§9); count-engine `memState` → shared Redis (§10b).
