# ADR-0022 V3 — the flip-readiness verdict (reference)

Companion to [ADR-0022](../0022-pre-flip-behavior-correctness-validation.md).
This is the concrete, operational definition of **V3**: the point where the
per-tenant bake stops being a wall of gauges and becomes a single, objective
**"green to flip?"** answer — plus the assertion that the stack computes the
*right* numbers, not merely the *same* numbers.

## What "green to flip" means, concretely

A tenant is **flip-ready** when BOTH halves are green:

1. **Convergence (data parity).** Every bake surface for the tenant agrees
   between the legacy flow (F1, `public`) and the Go flow (F3,
   `shadow_go_port`) — `bake_surface_mismatches == 0` — AND every surface has
   actually compared rows this tick (`bake_surface_compared > 0`, so a starved
   "no data" surface is never mistaken for agreement). This is expressed as a
   single per-tenant signal, `bake_tenant_converged{enterprise} == 1`.

2. **Behavior correctness.** The V3 acceptance suite
   (`services/oeecloud-worker/internal/verdict`) passes for the tenant — the
   ported compute produces the arithmetically-correct OEE/attribution/
   availability on known inputs. This is the half convergence cannot see: F1
   and F3 can **agree and both be wrong** (a shared bug in the ported compute
   moves both flows identically; the comparator only diffs the two, so it stays
   green). The suite pins the numbers to hand-derived arithmetic.

> **The whole stack is green to flip when BOTH tenants (CPACK=3, Incoplast=4)
> have `bake_tenant_converged == 1` sustained, AND the behavior suite passes for
> both.** CPACK's existing flip-critical gate — the `BakeSurfacePersisting`
> 24h-mismatch alert — is unchanged; V3 only *adds* signal on top of it.

## Part A — the convergence verdict (Prometheus)

`monitoring/prometheus/rules.yml`, group `packiot-flip-readiness`:

### Recording rule — `bake_tenant_converged{enterprise}`

```promql
bake_tenant_converged =
  (max by (enterprise) (bake_surface_mismatches) == bool 0)
  *
  (min by (enterprise) (bake_surface_compared) > bool 0)
```

Read it as two per-enterprise reductions multiplied:

| Factor | 1 when… |
|--------|---------|
| `max by(enterprise)(bake_surface_mismatches) == bool 0` | **no** surface for the tenant mismatches |
| `min by(enterprise)(bake_surface_compared) > bool 0` | **every** surface actually compared rows (none starved) |

The product is `1` only when both hold. It derives entirely by the
`enterprise` **label** — no tenant list is hardcoded in PromQL, so a third
mirrored tenant lights up automatically. If a tenant emits no bake series at
all, it has no `bake_tenant_converged` series → absent → treated as **not**
converged (the intended fail-safe).

> `enterprise="6"` also gets a series: the bake emits one pool-liveness surface
> (`customer_reports_shift_06`) under that label. It is the sync06 pool tenant,
> **not a flip tenant**; its convergence is incidental and harmless.

### Alert — `TenantNotFlipReady`

```promql
- alert: TenantNotFlipReady
  expr: bake_tenant_converged == 0
  for: 10m
  labels: {severity: info}
```

Fires **while** a tenant is not converged, so *ready-to-flip* is the explicit
event of this alert **resolving** for that enterprise. It is informational, not
a failure — the flip-critical failure alert stays `BakeSurfacePersisting` (24h,
untouched). The bake metric and CPACK's alert semantics are **not** modified;
V3 is purely additive.

### Dashboard

Grafana board **09 — ADR-0016 Bake** gains two panels (ids 20/21):

- **FLIP-READINESS — tenant converged** (stat, background-colored): green
  "FLIP-READY" per enterprise when `bake_tenant_converged == 1`, red "NOT READY"
  otherwise.
- **Convergence over time** (stepped timeseries): watch each tenant settle to
  `1` and stay before flipping.

The pre-existing per-surface mismatch/compared trend panels (ids 1/2, legend
`{{surface}} (e{{enterprise}})`) already carry the drill-down.

## Part B — behavior-correctness suite (Go)

`services/oeecloud-worker/internal/verdict` — the named acceptance suite. Same
ephemeral-Postgres approach as `internal/rollup/golden_test.go`, same
`-tags golden` lane, but a different question: golden = *regression* (freeze the
parity-proven SQL constants); verdict = *acceptance* (assert the domain math is
correct). It reuses rollup's `*ForParity()` accessors as its single source of
compute SQL — it copies no statement. Every scenario runs **tenant-parameterized**
for enterprise 3 and 4.

Each scenario's expected values are **derived by hand in the code comment** (the
A×P×Q / availability arithmetic) rather than reverse-engineered from a fixture —
a wrong "expected" would make the suite lie.

| # | Scenario | Grain / compute | Asserts |
|---|----------|-----------------|---------|
| 1 | OEE cascade | shift (`ShiftStatementsForParity`) | collapsed shift OEE == A×P×Q |
| 2 | PO lifecycle | PO recalc (`RecalcSQLForParity`) | `production_orders` A/P/Q attribution |
| 3 | Downtime classification | shift | planned vs unplanned → correct availability |

### Scenario 1 — OEE cascade, shift grain (OEE = 0.60)

Known 3h shift, one line: CAgg buckets sum to gross 10000 / net 9000 / ideal
100 per-min; three events tile the shift as running 7200s + planned stop 1800s +
unplanned 1800s.

```
available_time   = ts_total − ts_planned = 10800 − 1800 = 9000 s
ideal_production = (available/60)·ideal   = (9000/60)·100 = 15000
shift OEE        = net / ideal_production = 9000 / 15000  = 0.60

Independent A×P×Q proof (the "right number" check):
  Availability = running / available    = 7200 / 9000       = 0.8000
  Performance  = gross / (running_min·ideal) = 10000/(120·100) = 0.8333…
  Quality      = net / gross            = 9000 / 10000      = 0.9000
  A·P·Q = 0.8 · 0.8333… · 0.9 = 0.60 ✓   (running_min & gross cancel)
```

### Scenario 2 — PO lifecycle attribution (OEE = 0.45)

A PO that ran start→running→pause→finish leaves two
`production_orders_runtime` segments; the recalc consumer sums them: Σgross 6000,
Σnet 5400, Σavail 7200, Σrun 5760, Σplanned 1800; total = Σavail + Σplanned =
9000; ideal 100/min.

```
oee_quality      = net / gross                    = 5400/6000          = 0.90
oee              = net / ((total−planned)/60·ideal)= 5400/(120·100)     = 0.45
oee_availability = run / avail                     = 5760/7200          = 0.80
oee_performance  = oee / (availability·quality)    = 0.45/(0.80·0.90)   = 0.625
check A·P·Q = 0.80 · 0.625 · 0.90 = 0.45 = oee ✓
```

Unlike the shift grain (which stores a single collapsed OEE), the PO grain
stores A, P, Q **separately** — so this scenario asserts each component column.

### Scenario 3 — downtime classification → availability

Two identical lines, identical physical behaviour (2h running + 1h downtime).
The **only** difference is the classification flag on the downtime hour:

```
eq 201  PLANNED (status 5, planned_downtime=true):
   available = ts_total − ts_planned = 10800 − 3600 = 7200 ; running 7200
   availability = 7200 / 7200 = 1.000   (planned downtime EXCLUDED)
   oee = 900 / ((7200/60)·100) = 900/12000 = 0.075

eq 202  UNPLANNED (status 1, planned_downtime=false):
   available = ts_total − 0 = 10800 ; running 7200
   availability = 7200 / 10800 = 0.6667  (unplanned counts against it)
   oee = 900 / ((10800/60)·100) = 900/18000 = 0.05
```

This is precisely the case data-parity alone cannot catch: drop the
classification and BOTH flows compute the unplanned number — F1/F3 still agree,
and both are wrong. The suite asserts the two availabilities diverge correctly
(and `oee201 > oee202`).

## How to run

```bash
cd services/oeecloud-worker

# convergence rule / dashboard are declarative — validate shape:
python3 -c "import yaml,sys; yaml.safe_load(open('../../monitoring/prometheus/rules.yml'))"
promtool check rules ../../monitoring/prometheus/rules.yml   # if available

# behavior suite (needs an ephemeral Postgres; same lane as the golden tests):
docker run -d --name pg -e POSTGRES_PASSWORD=pw -p 5432:5432 postgres:15
export DATABASE_URL="postgres://postgres:pw@localhost:5432/postgres?sslmode=disable"
go test -tags golden ./internal/verdict -run Acceptance -v
docker rm -f pg

# compile-only (no DB): typechecks the golden lane
go vet -tags golden ./...
```

## Reading the verdict day-to-day

1. Open board 09. The **FLIP-READINESS** panel must show green (FLIP-READY) for
   **both** enterprise 3 and 4.
2. If red: the surface mismatch/compared trend panels name which surface and
   tenant broke it. `TenantNotFlipReady` (info) will be firing for that
   enterprise; `BakeSurfacePersisting` (warning, 24h) is the flip-critical one.
3. Convergence is necessary but not sufficient — confirm the behavior suite is
   green in CI for the flip commit. Only then is the stack "green to flip".
