# ADR-0014 — Extract OEE math from PostgreSQL into application layer

- **Status**: Accepted — implemented (engine live at measured parity 0/13,162 + 0/13,432; blessed 2026-07-06)
- **Deciders**: Emmanuel Podestá (Packiot backend)
- **Depends on**: ADR-0010 (Go decode + shadow_go_port), ADR-0012 (schema refactor + packiot_shadow), ADR-0013 (shadow-mirror control-plane parity)
- **Blocked by**: none. Blocks: full 3-flow parity (ADR-0012 Phase 4).

## Context

The Packiot OEE math (equipment_events derivation, runtime aggregates,
shift roll-ups, PO scoring) is currently spread across three layers of
PostgreSQL:

1. **Triggers** — 1 confirmed on `public.equipment_values`
   (`piot_set_shift_before_insert`). Runs `piot_set_shift_on_equipment_values()`
   which sets `id_shift`, `id_shift_hour`, `id_team` on every INSERT.

2. **PL/pgSQL functions** — dozens under the `piot_*` namespace:
   - `piot_create_area_runtime_{1hour,1day,1week,1month,shift}`
   - `piot_create_equipment_runtime_{1hour,1day,...,shift}`
   - `piot_create_equipment_values`, `piot_create_missing_minutes`
   - Customer-specific: `piot4_13_get_dt5min_po`, `piot4_13_get_microstops_po`,
     `piot4_13_get_production_po`, `piot4_13_get_production_shift_pos`

3. **pg_cron jobs** — schedule the `piot_create_*_runtime` functions on
   fixed cadences (1 min, 1 hour, daily, etc.).

## The problem

For ADR-0012's 3-flow refactor POC to reach full data parity, each
shadow destination (`packiot.shadow_go_port`, `packiot_shadow.public`)
would need the SAME triggers, functions, and pg_cron schedule as
`packiot.public`. That means:

- Duplicating N triggers × 3 schemas
- Duplicating M pg_cron entries × 2 databases
- Maintaining trigger contract compatibility as the refactor
  intentionally diverges the shadow schemas
- Any bug fix or schema change requires touching 3 mirror places

The refactor's WHOLE POINT is that `packiot_shadow` can differ from
`packiot.public` (`customer_dashboards` schema, ca_* CAgg naming,
retired matview families). Keeping identical triggers everywhere
directly contradicts that.

Deeper issue: **PL/pgSQL as a compute layer** for OEE math has costs
that only get worse at scale:

- **No unit tests**: PL/pgSQL functions require running Postgres for
  every test; CI is heavy and slow
- **Weak type safety**: no static analysis, no compile errors, no
  race detection
- **Debugging is painful**: no stack traces, `RAISE NOTICE` scattered
  logs, no dtrace/eBPF observability
- **Deploy risk**: schema migrations run PL/pgSQL DDL under exclusive
  lock — a bug in a function replaces the old one atomically with
  no canary
- **Compute + storage entangled**: DBAs need to reason about business
  logic; app engineers need to reason about SQL storage internals

## Decision

Extract OEE math from PostgreSQL into the application layer, one
subsystem at a time. Target home: **oeecloud-worker-go** (already
writes `equipment_values`, close to the source) or a NEW dedicated
service `oee-computer` (cleaner separation, higher cost).

Recommended landing: **oeecloud-worker** for now. It already owns
the write path; adding derived-write logic keeps state changes local.
Spinning up `oee-computer` becomes worthwhile only when oeecloud-worker
grows a second write pattern (RabbitMQ Streams, Kafka, etc.).

### What moves

1. **`piot_set_shift_before_insert` trigger** → oeecloud-worker's
   equipment_values writer sets `id_shift`, `id_shift_hour`, `id_team`
   before Building the Query. Same lookup logic in Go, tested
   independently.

2. **`piot_create_equipment_runtime_*` functions** (1hour/1day/1week/1month)
   → replace with TimescaleDB Continuous Aggregates (Materialized
   Views over the hypertable). Native compression + auto-refresh
   handles what the pg_cron jobs did manually. This item is largely
   already scoped by ADR-0012 Phase 3 (CAgg naming consolidation).

3. **`piot_create_area_runtime_*` functions** → oeecloud-worker
   emits area-scoped rollups from the equipment stream. Or (cheaper)
   materialize on-query via views that aggregate on the fly.

4. **Customer-specific functions (`piot4_13_*`)** → move to per-customer
   Go handlers keyed by `id_enterprise=13`. Keeps the OEE core
   business-agnostic; customer specifics stay opt-in.

### What STAYS in PostgreSQL

- **TimescaleDB hypertable partitioning + compression** — these are
  storage-layer concerns, not compute. Native Postgres extension.
- **Foreign key constraints** — referential integrity is the DB's job.
- **B-tree indexes** — same.
- **CAgg refresh policies** — TimescaleDB-native, opaque to app.

Not moving these: the DB is still the source of truth for data
integrity. We're extracting COMPUTE, not STORAGE.

## Consequences

### Positive

- **Shadow paths just need TABLES** — no triggers, no pg_cron jobs
  to duplicate. `packiot_shadow` can freely diverge because the
  compute is in Go, not PL/pgSQL
- **Full unit test coverage** — every OEE math path testable in Go
  with mock inputs, no Postgres dependency
- **Compile-time safety** — schema shape mismatches caught at build
  time, not runtime
- **Trace + profile with standard Go tooling** — pprof, expvar,
  Prometheus, OpenTelemetry
- **Deployable behind feature flags** — canary the Go implementation
  against the PL/pgSQL one, compare outputs, gradually cut over
- **Cross-flow parity trivial** — one Go writer fans out to all 3
  destinations (extension of ADR-0012 P3 routing table)

### Negative

- **Migration effort** — ~15-25 functions + 1 trigger to port,
  probably 2-4 sprints depending on how deeply the customer-specific
  functions are coupled to prod schemas
- **Coordination with pg_cron retirement** — until all functions
  ported, both worlds must coexist. `piot_create_*_runtime` calls
  from Go with pg_cron still firing = duplicate rows unless
  idempotent
- **Loss of DB-local transactional semantics** — trigger + INSERT
  in one transaction becomes 2 statements from Go, with potential
  for the second to fail after the first commits. Mitigated by
  idempotent UPSERT design

### Risks

- **Behavioral drift during migration** — Go implementation must
  produce byte-identical rows to the PL/pgSQL one during the
  parallel-run window. ADR-0008's comparator pattern is the right
  mitigation (already proven for mirror-worker fidelity checks)
- **Customer-specific logic (`piot4_13_*`)** may hide undocumented
  business rules. Port only after reading the source carefully;
  reach out to the customer if any function is genuinely opaque
- **Performance** — a well-tuned PL/pgSQL function can be faster
  than a Go loop because it stays in-DB. Benchmarking required.
  Fallback: for hot paths, keep the trigger but move ONLY the
  input transformation to Go

## Implementation phases

### Phase 1 — inventory + measurement (session 74+)
- Enumerate every `piot_*` function + which pg_cron jobs call each
- For each, note: rows read/written per invocation, avg execution time,
  business purpose, dependency chain
- Deliverable: `docs/adr/reference/designs/0014-oee-math-inventory.md`

### Phase 2 — port the shift setter (smallest, safest first)

**STATUS: SHIPPED BEHIND FLAG (2026-07-02)** — `internal/shiftresolver/`
ports `piot_set_shift_on_equipment_values()` +
`piot_get_shift_hour_by_equipment()` 1:1 (naive-week arithmetic with
negative week_begin, area-priority selection with NULLS LAST tiebreak,
fail-open). Implementation notes vs the original sketch:

- The port started as a companion `UPDATE … SET col = COALESCE(col, $n)`
  queued right after each UPSERT in the same pgx.Batch — trigger-parity
  "fill only when NULL" semantics with zero churn on the 5 INSERT
  builders. It also fills `ts_value_production` (the trigger's second
  job). id_team turned out NOT to be set by this trigger — dropped from
  scope.
- **FOLD (2026-07-13, flag `SHIFT_FILL_FOLDED`, default off):** the three
  columns are now optionally folded straight INTO the UPSERT (INSERT
  columns + `ON CONFLICT DO UPDATE SET col = COALESCE(equipment_values.col,
  EXCLUDED.col)`, with `ts_value_production = ($1)::date` reusing the
  ts_value bind for the identical session-tz cast). This halves the
  per-metric statement count (~60→~40) on the equipment_values surface.
  The flag selects: on → folded UPSERT + no separate UPDATE; off → the
  legacy split above. DBA-ruled bake-safe (ZERO live triggers on
  public + packiot_shadow, so no BEFORE-INSERT interaction); flag exists
  purely for hot-path rollback-by-flag.
- `SHIFT_RESOLVER_ENABLED=true` fills shifts on ALL flows. The
  `piot_set_shift_before_insert` trigger was RETIRED after the 168h bake
  (DBA verified zero triggers on staging public + packiot_shadow public);
  the Go resolver is now the SOLE shift writer on every schema and flow.
- Bake gauge: /d/3-flow-parity "shift divergence" + "Go-unresolved"
  panels (24h windows) — must stay 0 across a shift cycle after each
  `SHIFT_FILL_FOLDED` flip.
- Unit tests cover the week-offset math hand-derived from the SQL
  (UTC wb=0/1, Sao Paulo wb=-3000 both sides of the week origin,
  UTC-vs-local day boundary), the ORDER BY port, and window edge
  inclusivity.

Phase 2 close-out DONE: 168h bake passed → `piot_set_shift_before_insert`
dropped on packiot.public → Go fills all source_types. The remaining
`SHIFT_FILL_FOLDED` flip is a throughput optimization, not a correctness
gate.

### Phase 3 — port runtime aggregates
- Convert `piot_create_equipment_runtime_1hour` etc. into TimescaleDB
  CAggs (ADR-0012 Phase 3 overlap)
- Retire pg_cron entries as CAggs come online
- Same trigger-retirement pattern per rollup

### Phase 4 — port customer-specific functions
- One customer at a time, starting with c13 (most complex per function
  count)
- Add customer_id to relevant queries + Go handler map

### Phase 5 — retire piot_* namespace
- Once all functions ported + baked, DROP FUNCTION piot_% CASCADE
- Update `edge-api/schema.sql` to reflect new reality
- Documentation cleanup

## Testing strategy — thorough (each port gets ALL of the below)

The whole point of this ADR is that OEE math becomes testable in Go
without a Postgres dependency. Every ported function ships with a
full test pyramid — anything less and we've paid the migration cost
without collecting the payoff.

### 1. Unit tests — every function gets a table-driven test suite

For each ported `piot_*` function:

- **Happy-path fixtures** sampled from real staging `equipment_values`
  rows. Store as JSON fixtures in `services/oeecloud-worker/testdata/`
  so drift is caught if edge-api ever changes the shape.
- **Edge cases** enumerated explicitly:
  - Empty input (0 rows, NULL values on every field)
  - Boundary times: exact shift-boundary ts_value, week_begin=0,
    week_begin=-3000 (Sunday wrap)
  - Missing FK targets: id_equipment=999999, id_shift=NULL
  - Duplicate rows (same ts_value + id_equipment)
  - Timezone edges: UTC-aware vs naive timestamps
- **Negative cases**: rows the function should REJECT (bad
  conversion_factor, negative production_incr). Verify the Go
  implementation matches the PL/pgSQL rejection behavior byte-for-byte.
- Minimum coverage bar: 90% line coverage per handler, 100% branch
  coverage on the OEE-math paths.

### 2. Parity comparator — ADR-0008 pattern, bake window

For each ported function, run **BOTH implementations in parallel**
for at least a full production cycle (typically 1 week per rollup
granularity):

- PL/pgSQL trigger stays enabled, writes to `packiot.public`
- Go implementation writes to `packiot.shadow_go_port` (or a
  dedicated `packiot_go_math` schema)
- Comparator service diffs the two datasets row-by-row on a schedule
  (mirroring `services/mirror-worker-go/internal/comparator/`
  patterns)
- Emit Prometheus fidelity metrics: `oee_math_divergence_total{path}`,
  `oee_math_divergence_delta_seconds{path}` for time-based fields
- Alert threshold: any divergence > 0.1% triggers a Grafana alert →
  ntfy. Bake window resets on every divergence spike
- Cut over from PL/pgSQL to Go only after 168 continuous hours of
  0 divergence

### 3. Property-based tests — catch corner cases hand-written tests miss

Use `go-testing/quick` (stdlib) or `pgregory.net/rapid` for
property-based:

- Property: `f_go(x) == f_plpgsql(x)` for random x in a bounded space
- Property: `f_go(f_go(x)) == f_go(x)` (idempotence for stateless
  functions)
- Property: `f_go(x)` is monotonic in production counters when
  input rows are in temporal order
- Runtime cap: 30s per property test in CI (property tests are
  slow); no cap when run manually via `go test -tags proptest`

### 4. Integration tests against real staging

Nightly job that runs the ported Go code against a snapshot of
staging equipment_values (last 24h) and compares the OEE math
outputs against `packiot.public`:

- Fixtures pulled fresh each night (avoid stale snapshot rot)
- Run in `oeecloud-worker/integration_test/` behind
  `//go:build integration` tag so `go test ./...` in dev doesn't
  hit the network
- Report divergence to `#packiot-oee-drift` Slack channel (or
  equivalent ntfy topic)

### 5. Performance benchmarks — retire PL/pgSQL only when Go is at parity

For each function, `go test -bench` with realistic input sizes:

- Small: 100 rows (per-minute rollup input)
- Medium: 6000 rows (per-hour rollup input)
- Large: 144000 rows (per-day rollup input)
- Measure: ns/op, allocs/op, P99 latency
- Compare vs `EXPLAIN ANALYZE` on the equivalent PL/pgSQL function
  under the same input
- Acceptance criterion: Go implementation within 2x of PL/pgSQL P99.
  If Go is >2x slower, either optimize or keep the trigger for
  that specific function

### 6. Chaos tests — inject faults, verify graceful degradation

Chaos-flavored integration tests that verify:

- **DB connection loss during compute**: Go handler must fail cleanly
  (return error, no partial writes). No half-computed rollups
- **NULL FK targets**: id_shift lookup returns 0 rows → Go writes
  id_shift=NULL, not id_shift=0
- **Time skew**: ts_value in the far future or past 1970-01-01 →
  Go rejects with typed error, PL/pgSQL parity confirmed
- **Concurrent writes**: two Go workers write same (ts_value,
  id_equipment) → ON CONFLICT DO UPDATE picks a deterministic winner
- Test framework: `github.com/testcontainers/testcontainers-go` for
  spinning up ephemeral Postgres + TimescaleDB, then intentionally
  killing containers mid-write

### 7. Documentation-as-test — every function has a runnable example

Each Go function ports the PL/pgSQL semantics but ALSO carries a
`ExampleFunctionName_...` test that renders in godoc. Two reasons:

- Reviewers can grok the function's contract by reading the doc
  without running any code
- The example is a real Go test that fails if the behavior changes
  — documentation stays in sync with the code automatically

### CI gate for each port

A port lands only when:

- [ ] Unit tests: 90% line coverage, 100% branch coverage on OEE
      paths, all pass
- [ ] Parity comparator: 168h continuous 0-divergence bake
- [ ] Property tests: pass in `-count=100` mode
- [ ] Integration tests: pass against last-24h staging snapshot
- [ ] Benchmark: within 2x of PL/pgSQL P99
- [ ] Chaos tests: all fault-injection scenarios covered
- [ ] Documentation example test runs green in CI

## What this unblocks

- ADR-0012 Phase 4 (full 3-flow parity): once compute is in Go,
  fanning to shadow paths is a routing-table extension, not a
  schema-replication project
- Simpler operator UX: schema changes stop requiring PL/pgSQL DDL
  rewrites
- Reproducible testing: `go test ./services/oeecloud-worker/...`
  covers the OEE math end-to-end without Postgres

## References

- ADR-0008 — comparator-as-fidelity-watchdog (the pattern for
  behavioral parity during migrations)
- ADR-0010 — Go port of Calc Production Counters (precedent for
  this kind of extraction)
- ADR-0012 — schema refactor (the primary consumer of this work)
- Stripe engineering: "How we moved from stored procedures to
  application code" — general industry pattern
- Amazon Aurora / Google Cloud SQL best practices: business logic
  in app, not DB
