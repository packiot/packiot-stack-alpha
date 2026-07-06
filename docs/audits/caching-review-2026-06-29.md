# Caching Review — 2026-06-29

**Scope:** in-application caching opportunities across edge-api (focus), mirror-worker-go, oeecloud-worker, edge-nodered, operator SPA.
**Question answered:** *where would caching produce a measurable performance gain, and what's the lightest mechanism that gives it?*
**NOT in scope:** CI build caching (covered in ADR-0006), Redis (only proposed once measured pain demands it).

---

## TL;DR — prioritized recommendations

| # | Where | What | Effort | Impact | Risk |
|---|---|---|---|---|---|
| **1** | **edge-api** | **API-key cache in `auth.middleware.ts`** (in-process LRU, ~50 entries, 60s TTL) | 0.5d | **High** (fires on every authenticated request) | Low (TTL absorbs api_key rotation within 60s) |
| **2** | **operator SPA** | **React Query / SWR for the 5s/12s polling endpoints** | 1-2d | **High** (network reduction + UX smoothness from stale-while-revalidate) | Low (additive; roll out per endpoint) |
| **3** | mirror-worker-go | In-memory `Equipment()` translator cache + packml_register snapshot loader | 1d | Medium (halves per-event SQL count, the translator is hot during catch-up windows) | Low (refresh on signal / restart) |
| **4** | edge-api | Response caching on `list-*` endpoints (in-process, 5-10 min TTL, invalidation on related mutations) | 1-2d | Medium (reduces TimescaleDB read load) | Medium (stale-data risk — needs invalidation discipline) |
| **5** | edge-nodered | Hasura `@cached` directive on hot polling queries | 0.5d | Medium (offloads Hasura → TimescaleDB) | Low (Hasura manages the cache) |
| **6** | edge-api | HTTP `Cache-Control` headers on `list-*` endpoints (browser-side) | 0.5d | Medium (free browser-side cache when operator hits list endpoints) | Low |
| **7** | Nginx reverse proxy | Cache GET responses at the proxy layer | 1d | Low-Medium | Medium (operator complexity, invalidation) |

**Recommendation: ship items 1, 2, 5 in phase 1 (week 1). Items 3 and 4 in phase 2 (once observability confirms there's measurable load to reduce). Items 6, 7 only if 1-5 haven't moved the needle.**

---

## edge-api findings (the headline opportunity)

### Today's state (zero in-process caching)

```bash
$ grep -rE "@nestjs/cache|cache-manager|CacheModule|@UseInterceptors" edge-api/src/
# (empty — no caching infrastructure installed)
```

Every request, every endpoint, every list — straight pass-through to TimescaleDB via `pg-promise`. This is fine at low traffic but explicitly leaves performance on the table.

### Hot path #1 — `auth.middleware.ts` (every authenticated request)

```ts
// edge-api/src/middleware/auth.middleware.ts
async use(req, res, next) {
  const token = req.headers['x-api-key'] || req.query.token;
  const idEnterprise = Number(req.query.idEnterprise);
  const isAuthorized = await this.auth.authorize(token, idEnterprise);  // ← every request, every endpoint
  // ...
}
```

```ts
// edge-api/src/data/DAO/auth-middleware/auth-apikey-dao.ts
async authorize(token, idEnterprise) {
  // Branch A — token only:
  await this.db.query(
    'SELECT id_enterprise FROM enterprises WHERE api_key = $1 AND active = true',
    [token]
  );
  // Branch B — with idEnterprise filter:
  await this.db.query(
    'SELECT api_key FROM enterprises WHERE id_enterprise = $1 AND active = true',
    [idEnterprise]
  );
}
```

**Every authenticated request hits TimescaleDB.** The `enterprises` table is tiny (~10-20 rows), changes ~never (api_key rotation is a deliberate ops action, not a normal event). This is the **single highest-ROI caching change in the entire codebase.**

**Recommended fix:**

```ts
// NestJS @nestjs/cache-manager — built-in, no Redis required
@Module({
  imports: [
    CacheModule.register({
      ttl: 60_000,   // 60 seconds
      max: 100,      // ~10x the actual enterprise count
    }),
  ],
})
```

```ts
// auth-apikey-dao.ts
async authorize(token: string, idEnterprise: number): Promise<boolean> {
  const cacheKey = `auth:${token}:${idEnterprise || 'noenterprise'}`;
  const cached = await this.cache.get<boolean>(cacheKey);
  if (cached !== undefined) return cached;

  // ... existing DB query ...

  await this.cache.set(cacheKey, result, 60_000);
  return result;
}
```

**Trade-off:** an api_key rotation propagates within 60s instead of instantly. For a SOC2-style requirement of "instant revocation", we'd need either a shorter TTL (10s — still useful) or an explicit cache-bust on rotation. The current ops cadence is rotation by ticket → 60s is fine.

### Hot path #2 — `list-*` endpoints (mostly-static reference data)

20 GET endpoints in `src/usecases/*/list-*/`. Categorized by churn rate:

| Endpoint | Churn | Cache TTL recommendation |
|---|---|---|
| `list-enterprises` | ~never | 10 min |
| `list-sites`, `list-areas`, `list-equipments`, `list-lines` | weekly | 10 min |
| `list-packml-register` | weekly (CS Admin) | 5 min |
| `list-shifts`, `list-shift-hours` | weekly-monthly | 10 min |
| `list-user-roles`, `list-users` | rare (user provisioning) | 5 min |
| `list-labels`, `list-samples` | **per-second during a PO run** | ❌ DO NOT CACHE |
| `current-production-order` | **per-action** | ❌ DO NOT CACHE |
| `get-pending-downtimes`, `get-justified-downtimes` | **real-time** | ❌ DO NOT CACHE |

**Recommended fix:**

```ts
import { Controller, Get, UseInterceptors, CacheInterceptor, CacheTTL } from '@nestjs/common';

@Controller('enterprises')
@UseInterceptors(CacheInterceptor)
export class ListEnterprisesController {
  @Get()
  @CacheTTL(10 * 60 * 1000)  // 10 minutes
  async list() { return this.svc.execute(); }
}
```

**Trade-off:** invalidation on related mutations. When `POST /enterprises/edit` lands, the cached `GET /enterprises` is stale for up to 10 min. Two patterns:

1. **TTL-only (accept staleness, simpler):** ops accept that operator sees old reference data for ≤10 min after a CS Admin edit. Most safe.
2. **Cache-bust on mutation (active invalidation):** every edit/create/delete handler calls `cache.del('GET /enterprises:...')`. More complex; risk of forgetting a path.

For Packiot's scale + CS Admin's edit frequency, **TTL-only is almost certainly enough**. Edits are rare; eventual consistency at 10-min scale is fine.

### What I would NOT cache in edge-api

- `current-production-order` — operator UI's freshness depends on this; caching == stale current state
- `get-pending-downtimes` — real-time signal; caching breaks the operator's mental model
- `list-samples`, `list-labels` — per-PO mutations during a run; caching = wrong counts
- Any POST / PATCH / DELETE — write paths obviously, but worth stating

---

## operator SPA findings (the user-facing opportunity)

### Today's state

```jsx
// operator/src/Services/api.js
const api = axios.create({ baseURL: import.meta.env.VITE_API_URL });
```

```jsx
// operator/src/Pages/Home/index.jsx — raw setInterval polling
useEffect(() => {
  productionTimer = setInterval(() => fetchData(), 12000);
  eventsTimer    = setInterval(() => fetchEvents(), 5000);
}, [packmlTopic]);
```

Each timer fires `await api.post(...)`. **Zero deduplication, zero cache, zero stale-while-revalidate.** Three windows open in three browsers = 3× the network traffic for identical data.

`localStorage` is used for auth state + selected enterprise/site/area scoping. That's good. But no caching of API responses.

### Recommended fix — React Query (TanStack Query)

```jsx
// operator/src/Services/queries.js (new file)
import { useQuery } from '@tanstack/react-query';
import { api } from './api';

export function usePendingEvents(packmlTopic) {
  return useQuery({
    queryKey: ['pending-events', packmlTopic],
    queryFn: () => api.post('/pending-events', { packmlTopic }).then(r => r.data),
    refetchInterval: 5000,
    staleTime: 4000,         // ← within 4s, return cached without refetch
    gcTime: 30000,           // ← keep in memory for 30s after no observer
    refetchOnWindowFocus: true,
  });
}

export function useProductionData(packmlTopic) {
  return useQuery({
    queryKey: ['production', packmlTopic],
    queryFn: () => api.post('/production', { packmlTopic }).then(r => r.data),
    refetchInterval: 12000,
    staleTime: 10000,
  });
}
```

```jsx
// Home/index.jsx becomes:
const { data: pendingEvents } = usePendingEvents(packmlTopic);
const { data: production } = useProductionData(packmlTopic);
// No more setInterval, no more local state for fetched data
```

**Wins:**
- **Multi-component deduplication** — if 3 components ask for `pending-events`, ONE network call satisfies all 3.
- **Stale-while-revalidate** — UI shows cached data instantly while fresh data fetches; no loading spinners on every poll tick.
- **Background refetch** — automatic pause when tab is in background (browser API), resume on focus. Free network savings when operator switches windows.
- **Mutation invalidation** — `queryClient.invalidateQueries(['pending-events'])` after a justify/edit lets the next render fetch fresh.
- **Devtools** — React Query devtools panel shows every cache entry + state, makes debugging painless.

**Trade-off:** adds the `@tanstack/react-query` dependency (~13 KB gzipped). Smaller than most icon libraries. The Provider wiring is one-time.

### What about the polling cadence itself?

`fetchEvents` every 5s is aggressive. With React Query's `staleTime: 4000`, the UI feels reactive while the network fires only on actual state changes. After this lands, consider:

- **GraphQL subscriptions** (via Hasura) for `pending-events` — replaces polling entirely with push. Bigger refactor; separate ADR. **Out of scope for this review.**
- **`navigator.onLine` + `visibilitychange` integration** — pause polling when tab hidden, queue mutations when offline. Already largely handled by React Query's `refetchOnWindowFocus` + `online` features.

---

## mirror-worker-go findings (the worker hot paths)

### Today's state

```go
// internal/translate/translate.go
func (t *Translator) Equipment(ctx, prodEquipmentID int) (int, error) {
  var prodTopic string
  found, err := t.prod.SelectOne(ctx,
    `SELECT pr.packml_topic FROM packml_register pr
      WHERE pr.id_equipment = $1 AND pr.id_enterprise = $2
      ORDER BY pr.active DESC NULLS LAST, length(pr.packml_topic) ASC,
               pr.id_packml_register ASC LIMIT 1`,
    ...)
  // then look up staging via topic — second SELECT
}
```

**Two SQL queries per `Equipment()` call.** Called by:
- Every `event-justified`, `event-edited`, `event-splitted` replay (via `EquipmentEvent`)
- Every entry the events-reconciler processes (every 60s, batch=200)

During catch-up windows (when the events reconciler is bridging an ID gap), this fires thousands of times per minute.

### Recommended fix — in-memory `Equipment()` cache

```go
// internal/translate/cache.go (new)
type equipmentCacheEntry struct {
  stagingID int
  cachedAt  time.Time
}

type Translator struct {
  // ... existing fields
  eqCache   map[int]equipmentCacheEntry  // prod_eq_id → staging_eq_id
  eqCacheMu sync.RWMutex
  eqCacheTTL time.Duration  // 5 min — packml_register changes rarely
}

func (t *Translator) Equipment(ctx, prodEquipmentID int) (int, error) {
  t.eqCacheMu.RLock()
  if entry, ok := t.eqCache[prodEquipmentID]; ok && time.Since(entry.cachedAt) < t.eqCacheTTL {
    t.eqCacheMu.RUnlock()
    return entry.stagingID, nil
  }
  t.eqCacheMu.RUnlock()

  // ... existing DB lookups ...

  t.eqCacheMu.Lock()
  t.eqCache[prodEquipmentID] = equipmentCacheEntry{stagingID, time.Now()}
  t.eqCacheMu.Unlock()
  return stagingID, nil
}
```

**Trade-off:** if a CS engineer edits prod packml_register (rare), cached entries are stale for up to 5 min. Acceptable. For instant invalidation, expose a `POST /admin/cache/invalidate` endpoint and call it after CS Admin DB changes.

**Expected impact:** ~120 hot prod equipments × 5 min TTL = ~24 SQL queries / 5 min instead of 200+/min. ~99% reduction on the translator's read load during catch-up.

### NOT recommended — caching `mirror_id_map` lookups in-process

The `mirror_id_map` TABLE is **already a cache** (the persistent layer for cross-system ID translation). Adding an in-process L1 cache on top:

- Pro: avoids the SQL roundtrip for hot entries
- Con: invalidation gets complex (every reconciler insert must propagate; cross-goroutine consistency matters)
- Con: marginal benefit — pg indexes make the lookup ~1ms; the table is small

**Verdict:** not worth the complexity. Leave mirror_id_map as the single cache layer.

---

## oeecloud-worker findings

Per the project memory: oeecloud-worker **already has** an in-memory `packml_register` cache (loaded at boot, refreshed periodically). That's the right architectural choice for its workload.

**Other opportunities:**
- **Per-equipment state-machine** — likely already in-memory (Go workers idiomatically keep state per-goroutine)
- **Shift boundary lookups** — checked per event; could be precomputed at shift-start and held in memory. Worth a focused review of `internal/processor/` if there's measurable load.

**Recommendation:** no caching changes needed; if observability shows a hot SQL path here, revisit.

---

## edge-nodered findings

Node-RED flows make repeated HTTP calls to:
- **Hasura GraphQL** (frequent — operator-flow data)
- **edge-api** (occasional — control plane mutations)

### Recommended — Hasura `@cached` directive on hot queries

```graphql
query GetEnterpriseEquipments($id_enterprise: Int!) @cached(ttl: 300) {
  equipments(where: {id_enterprise: {_eq: $id_enterprise}}) { ... }
}
```

Hasura community edition supports this on a subset of queries (read-only, no subscriptions, no auth-dependent variability). The cache is in-Hasura, not Redis; configurable TTL per query; automatic invalidation on the underlying table's writes (if the metadata is configured to track that).

**Trade-off:** Hasura's caching is opaque to clients (no `Cache-Control` headers exposed); operator can't tell it was cached. Fine for our use case.

### Recommended — Node-RED flow context with TTL for `edge-api` calls

The flows that call `edge-api` for control-plane data can use Node-RED's flow context to cache the response with a TTL:

```js
const ctx = flow.get('cacheCtx', 'memory') || {};
const entry = ctx[cacheKey];
if (entry && Date.now() - entry.t < 60_000) {
    return entry.v;
}
// ... do the http call ...
ctx[cacheKey] = { v: response, t: Date.now() };
flow.set('cacheCtx', ctx, 'memory');
```

Simple pattern; respects Node-RED's existing context model; no new deps.

---

## What to defer / explicitly NOT do (for now)

### Redis

Earlier in today's session I explicitly argued against adding Redis without measured pain. That stance stands. **None of the recommendations above require Redis.** All in-process options handle the load profile we have today.

When Redis WOULD become justified:
- We add a second edge-api instance behind a load balancer (cache coherence between instances)
- We measure that the in-process cache hit rate is high enough that NOT sharing it across instances costs measurably
- We start sharing session state, rate-limit counters, idempotency keys across services

None of those are true today.

### Service worker / PWA offline

Significant operator-app rewrite. Better tackled as a coherent offline-first redesign (links into ADR-0001's local-first philosophy). Out of scope.

### CDN / edge caching

The operator SPA's static assets (JS, CSS, images) absolutely should be served with long-lived `Cache-Control` headers + a CDN. That's a separate ops change (Nginx config + Cloudflare or similar). Worth doing but not in this review's scope.

---

## Measurement before/after

Before shipping any of items 1-5, capture baseline metrics:

```promql
# edge-api request count + p95 latency per endpoint
http_server_duration_seconds_count{job="edge-api"}
histogram_quantile(0.95, http_server_duration_seconds_bucket{job="edge-api"})

# TimescaleDB query count + duration via pgbouncer
pgbouncer_pools_server_active{database="packiot"}
```

After each cache lands, observe:
- Cache hit rate (instrument the cache lookup: `cache_lookups_total{result="hit|miss"}`)
- Downstream DB query count reduction (compare 1h windows pre/post deploy)
- Endpoint p95 latency reduction (especially `auth.middleware` overhead, which fires on every request)

**The measurement is what proves the caching was worth it.** Without instrumentation, "we added caching" is just a vibe.

---

## Phased rollout — recommended

| Phase | Items | Total effort | Validates |
|---|---|---|---|
| **Phase 1** | Item 1 (auth-key cache), Item 2 (React Query in operator), Item 5 (Hasura `@cached`) | ~3 days | The low-risk, high-impact set; touches the hottest paths first |
| **Phase 2** | Item 3 (mirror-worker translator cache), Item 4 (list-* response cache) | ~2 days | Worker-side + edge-api list-endpoint coverage, only if phase-1 metrics show remaining headroom |
| **Phase 3** | Item 6 (HTTP `Cache-Control` headers), Item 7 (Nginx proxy cache) | ~2 days | The defensive layer; only if measured load persists |

**Total: ~7 days across 3 phases**, sequenced so each phase is independently shippable and observable.

---

## Open questions

1. **Cache invalidation policy for list endpoints.** TTL-only (simpler, eventual consistency at 10-min scale) vs active cache-bust on mutations (complex, instant consistency). Recommendation above is TTL-only; needs explicit confirmation.
2. **Operator SPA — React Query vs SWR.** Both are excellent; React Query has more features (mutations, query invalidation), SWR has a smaller surface. **Recommendation: React Query** for the long-term feature set.
3. **NestJS cache-manager backend.** Default is in-memory (sufficient). Alternative is the `cache-manager-redis-yet` backend (Redis) for shared cache — defer until Redis is justified.
4. **Hasura cache — community vs enterprise.** Verify which directives are available on the Hasura version we run. Community edition has `@cached` with some limitations.
5. **mirror-worker translator cache — refresh strategy.** TTL-only vs explicit invalidation endpoint vs SIGHUP-style signal handler.

---

## Cross-references

- [`docs/archive/production-out-of-scope.md`](production-out-of-scope.md) — caching changes touch `staging` only; no production assets affected
- [`docs/adr/0006-workflow-infrastructure-refactor.md`](adr/0006-workflow-infrastructure-refactor.md) — CI build caching (Docker buildx, Go modules, npm) is covered there, NOT here
- [`docs/adr/0001-edge-persistence-intermittent-connectivity.md`](adr/0001-edge-persistence-intermittent-connectivity.md) — long-term local-first design that makes some of these caches obsolete (operator UI reads from local DB instead of cloud)
