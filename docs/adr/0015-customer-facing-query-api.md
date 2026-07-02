# ADR-0015 — Customer-facing composable query API + screen customization

- **Status**: PROPOSED (2026-07-02)
- **Context trigger**: product direction — customers composing their own
  queries/views; front4/operator per-user screen customization
- **Depends on**: ADR-0012 (pools = tenancy), ADR-0014 (CAggs = grains),
  task #86 outcome (refdata-api = the read-API seed)

## The domain insight that shapes everything

What Packiot customers would compose is NOT arbitrary entity graphs —
it is **analytics**: metrics (net production, scrap, OEE, availability,
speed) × dimensions (enterprise → site → area → equipment, shift, team,
product, order) × time grains (1min/10min/1hour/1day…) × windows/filters.
That is a SEMANTIC LAYER workload, and the refactor already built its
substrate:

| Need | Already exists |
|---|---|
| Tenancy isolation | pool `customer_id` + proven planner inlining |
| Time grains | the CAgg families (agg_*_1min/10min/1hour, 1s stream) |
| Entity hierarchy | reference tables (synced to F3) |
| Legacy name compat | façade views |
| Read-API seed + contract discipline | refdata-api endpoint-table |

## Options

**A. Code-first GraphQL API** (NestJS/gqlgen resolver layer, schema as
code — NEVER DB-metadata tracking, per the 165-table lesson). Great
for entity browsing + frontend flexibility; WEAK at composable
aggregations (custom grains/windows need a bolted-on DSL anyway).

**B. Semantic-layer API** (metrics catalog + query DSL over CAggs —
cube.dev-shaped, but ours): `POST /v1/query {metrics, dimensions,
grain, window, filters}` → SQL generated against the right CAgg with
customer_id enforced. Exactly matches the analytics workload; naturally
bounded (catalog = allowlist); grains map 1:1 to CAggs.

**C. Hasura/PostgREST style DB-as-API** — REJECTED (this session's
whole retirement arc is the evidence).

## Decision (proposed)

**B first, A later only if demanded.** Phases:

1. **P1 — semantic catalog in the query API**: evolve refdata-api →
   `query-api`: metric/dimension catalog endpoint + composable query
   endpoint compiling to CAgg SQL. Tenancy = mandatory customer_id
   claim → pool/CAgg filter injected server-side. Internal consumers
   (front4/operator) adopt it first = the bake.
2. **P2 — screen customization**: `user_screen_config` storage (layout
   JSON per user/role) + widget registry where every widget binds to a
   P1 catalog query. Frontend-only flexibility; zero new query power.
3. **P3 — external customers**: authn (API keys per customer), rate +
   cost limits (grain×window budget), saved views, versioned catalog.
4. **P4 — GraphQL façade (CONDITIONAL)**: only if customer tooling
   demands GraphQL specifically; schema generated FROM the P1 catalog
   (code-first), persisted queries only for untrusted clients.

## Non-negotiables (paid for in this session's scars)

- API contract decoupled from table layout (catalog indirection — the
  refactor must stay free to move storage)
- Tenancy in the API layer via pool customer_id; never per-customer DB
  roles
- Explicit contract table + guard tests (refdata-api pattern)
- Every composition path bounded: catalog allowlist, depth/cost caps,
  statement_timeout
- Live-traffic verification before declaring any surface done

## First implementation slice (next session candidate)

`GET /v1/catalog` + `POST /v1/query` supporting: metrics
{net_production, gross_production, scrap, avg_speed}, dims {site, area,
equipment, shift}, grains {1min,10min,1hour} (→ the agg_* CAggs),
window ≤ 90d, customer_id mandatory. front4 mission-control widgets as
first consumer.
