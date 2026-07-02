# Hasura review — is it earning its complexity?

- **Status**: Draft review (2026-07-02)
- **Author**: Emmanuel Podestá
- **Provocation**: this exists because the schema refactor (ADR-0012)
  keeps stumbling over Hasura re-tracking overhead. Every migration
  requires a `POST /v1/metadata` re-track cycle. Is that overhead
  worth what Hasura actually delivers for us?

## TL;DR

**Empirical finding**: Hasura is currently doing **5–10% of what
it's designed for**. Same amount of value could be delivered by
much simpler technology at lower recurring cost + refactor overhead.

**Recommendation**: NOT an immediate retire — the switching cost is
real. But **flag it as a candidate to retire after ADR-0012 lands**,
run the numbers on Hasura Cloud spend vs alternatives, and pilot one
of the alternatives in parallel to prove viability.

Decision belongs to product + backend collectively.

## What Hasura is actually used for (empirical)

Enumerated 2026-07-02 via Hasura Cloud API + repo grep.

**Consumers** (only ONE found):
- `edge-node-red` `GraphQL` flow tab — reads reference data

**Query patterns** (from named nodes in `edge-node-red/flows/GraphQL.json`):
- `GET_LANGUAGE_PACKS` — i18n strings
- `GET_OPERATOR_ENTITIES_PER_ROLE` — auth-related lookups
- `GET_OPERATOR_ENTITIES` — hierarchical dropdown data
- `GET_EVENTS_TIMELINE` — recent events feed
- `GET_SHIFT_HOURS` (DAY/WEEK) — shift schedule
- `Fetch Downtime Reasons` — enum-like reference data

All **SELECT** patterns. No mutations. No subscriptions. No actions.

**Consumers NOT using Hasura** (confirmed via grep):
- `operator` SPA — no GraphQL / Apollo / urql packages
- `front4` SPA — no GraphQL / Apollo / urql packages
- All Go services (`oeecloud-worker`, `edge-transformer`,
  `mirror-worker-go`, `shadow-mirror`) — zero `/v1/graphql` references
- `edge-api` NestJS — no outbound GraphQL calls

## What Hasura's tracked configuration says

| Feature | Staging count | Utilization |
|---|---|---|
| Tracked tables | **165** | ~7 named queries → ~4% used |
| Tracked functions | **105** | Unknown; likely mostly aspirational |
| Actions | 0 | Not using |
| Remote schemas | 0 | Not federating |
| Event triggers | 0 | Not using webhook-on-data-change |
| Cron triggers | 0 | Not using scheduled queries |
| Roles with permissions | 3 (`sudo`, `test`, `user`) | Bare minimum RBAC |

**Interpretation**: the Hasura instance was set up to expose ~everything
"in case somebody wants to query it," but the actual query patterns
touch a small fraction. The other 155+ tracked tables cost us:
- Metadata sync friction on every schema refactor (ADR-0012 pain)
- Attack surface (any tracked table with a permission bug is an
  RBAC leak vector)
- Cognitive load — new engineers see "165 tables tracked" and
  assume all are consumed

## Cost accounting

### Direct costs

- **Hasura Cloud strong-cicada project** — recurring monthly bill.
  Need finance to pull actual number; ballpark: $50–200/month
  depending on tier
- **Staging Docker Hasura** — no direct cost (uses shared EC2), but
  ~200 MB RAM + startup overhead
- **Container** in every developer's dev stack

### Indirect costs (harder to quantify but real)

- Every ADR-0012 schema refactor requires:
  1. Change DDL in edge-api migration
  2. Run migration
  3. Re-track affected tables in Hasura Cloud (manual admin panel work
     unless codified)
  4. Test each consumer's query still works
- **Documentation gap** — Hasura Cloud metadata isn't versioned in git,
  it lives in the admin panel. Every rebuild requires manual re-track
- Two sources of truth: `edge-node-red/hasura/metadata.json` (staging
  copy) vs Hasura Cloud (prod). They can drift silently

## Alternatives

### Option A — Replace with `pg_graphql` (Postgres extension)

**What it is**: Postgres extension that auto-generates a GraphQL API
from your schema, running INSIDE Postgres. Zero external service.
Used by Supabase.

**Pros**:
- Zero recurring cost — it's a Postgres extension
- Metadata IS the schema — no separate tracking
- Enterprise-grade (Supabase uses it in production for millions of
  users)
- Row-level security via native Postgres policies
- SQL comments become GraphQL descriptions

**Cons**:
- Less rich RBAC than Hasura's role model — you'd use Postgres RLS
- No actions / remote schemas / event triggers (we don't use those
  anyway)
- Not yet available on managed Postgres services universally
  (TimescaleDB self-hosted → works)

**Migration effort**: enable extension in edge-api migration, install
`postgraphile` for gateway, rewrite the ~7 edge-node-red queries.
~1 sprint.

### Option B — PostgREST (auto-generated REST from schema)

**What it is**: single Haskell binary that serves REST endpoints
auto-derived from Postgres schema. Zero code.

**Pros**:
- Radically simpler than Hasura + GraphQL — a `GET
  /language_packs?language=eq.pt` returns JSON
- 15 MB memory footprint, sub-millisecond query planning
- Rich filter syntax already good enough for our patterns
- Used at scale (Supabase's data API layer)

**Cons**:
- REST not GraphQL — edge-node-red would need small rewrites
- Same RLS-not-role limitation as pg_graphql
- Not a drop-in for anything expecting GraphQL

**Migration effort**: deploy PostgREST container, rewrite 7 node-red
queries to REST. ~3-5 days.

### Option C — Custom Go GraphQL server tailored to actual queries

**What it is**: write ~200 lines of Go that responds to the exact 7
queries edge-node-red makes.

**Pros**:
- We control everything — no over-tracking, no metadata sync
- Testable in Go with standard tooling
- Reuses existing patterns from `oeecloud-worker`
- Zero external dependencies

**Cons**:
- We now own it — bug fixes, feature requests
- Not future-proof — every new query pattern needs code

**Migration effort**: 1-2 days. Code volume trivially small.

### Option D — Migrate the reads to `edge-api` REST endpoints

**What it is**: expose the 7 reference-data reads as new endpoints
on `edge-api` NestJS.

**Pros**:
- Single point of API consumption — `edge-api` becomes the entire
  API layer (mutations already there)
- Existing auth path (API key + user_logs audit)
- No new services to run

**Cons**:
- Grows edge-api scope
- Loses the "GraphQL flexibility" narrative (though we don't use
  that flexibility anyway)

**Migration effort**: 1-2 days for the endpoints, 1 day to migrate
edge-node-red calls.

## Comparison matrix

| Criterion | Hasura | pg_graphql | PostgREST | Custom Go | edge-api REST |
|---|---|---|---|---|---|
| Recurring cost | $50-200/mo | $0 | $0 | $0 | $0 |
| Ops complexity | High | Low | Low | Low | Zero |
| Metadata sync overhead | High | None | None | None | None |
| Handles current use case | ✅ | ✅ | ✅ | ✅ | ✅ |
| Handles future GraphQL needs | ✅ | ✅ | ❌ | Coded per case | ❌ |
| Team familiarity | Yes | No | No | Yes (Go) | Yes (TS) |
| Migration effort | — | 1 sprint | 1 week | 1-2 days | 2-3 days |

## Migration risk

**Low-risk**: edge-node-red is the sole consumer and its queries are
enumerable + finite (~7). Any alternative that responds to those 7
queries works.

**Coordination**: edge-node-red flows would need rewriting per option
chosen. Node-RED HTTP nodes make this trivial regardless of target
API shape.

**Hidden risk**: are we SURE nothing else queries Hasura? Two ways to
verify before pulling the plug:
1. Enable Hasura Cloud query logging + observe for 30 days
2. Search customer-facing PowerBI reports for any GraphQL endpoint
   references (unlikely, but check)

## Recommendation

**Do NOT retire immediately**. But:

1. **Enable Hasura query logging for 30 days** to confirm the
   enumeration is complete
2. **Pilot Option D (edge-api REST)** — it's cheapest, uses tools we
   already run, and closes with product/backend collaboration
3. **After PowerBI compat work lands** (task #81), decide based on
   the logged query data
4. **If retiring**: give customers 90-day deprecation notice on the
   GraphQL endpoint. Edge-node-red owns the migration.

**Estimated benefit** if we retire Hasura in favor of Option D:
- ~$600-2400/year direct cost savings
- Retire 1 whole service (staging Docker Hasura)
- ADR-0012 schema refactor unblocked from re-tracking overhead
- One less production-critical vendor dependency

**Estimated cost** of NOT retiring:
- Ongoing metadata sync friction for every schema change
- Continued 165-table over-tracking security surface
- Bill continues indefinitely

## Open questions for the team

1. Are there any external integrations (customer BI tools, mobile
   apps we don't own, partner systems) that hit Hasura's GraphQL
   endpoint? If YES, retirement is more complex
2. Is Packiot's roadmap moving TOWARD or AWAY from GraphQL? If
   toward: keep Hasura or invest in a lightweight alternative. If
   away: retire it
3. Does anyone on the team have institutional knowledge of WHY
   Hasura was chosen originally? Understanding the "why" prevents
   repeating the same reasoning after retirement

## References

- `edge-node-red/flows/GraphQL.json` — the entire consumer surface
- `docs/adr/0012-schema-refactor-and-multitenancy-pool.md` — refactor
  that keeps stumbling on Hasura re-tracking
- Hasura Cloud project: `strong-cicada-30.hasura.app` (public URL
  `gqlpiot.packiot.com`)
- Staging Docker Hasura: `stack-hasura-1` on port 8081
