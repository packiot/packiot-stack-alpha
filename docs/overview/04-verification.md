# Verification — how we know the port is correct

> Audience: engineers and reviewers. The methodology that produced
> **0 mismatches / 32,848 rows**, and how to use each layer.
>
> Status date: 2026-07-06.

## The verification stack, bottom to top

| Layer | Proves | Where |
|---|---|---|
| Unit + guard tests | Formulas and load-bearing SQL fragments can't silently change (e.g. "phase B must remain an inner join", "the amber bug must stay") | `internal/rollup/*_test.go` etc., every PR |
| Golden fixtures (CI) | The exact shipped SQL produces exact expected outputs on a real Postgres — incl. the IF-FOUND semantics tripwire | `internal/rollup/golden_test.go`, `go test -tags golden`, ephemeral postgres:15 in `go-services.yml` |
| **Differential harness** | Old and new produce identical output on identical real inputs | `cmd/port-parity` — see below |
| Bake comparator (24/7) | The two engines agree on LIVE streaming data, continuously | `internal/bake/`, `/d/bake-flow-parity` |
| Identity fingerprints (24/7) | Two same-engine flows are byte-equal — a whole-system completeness probe | same dashboard, `bake_identity_mismatch` |
| Prod-read fidelity | Customer report ports match prod's own output (SELECT-only) | e.g. speed33 63/68 exact, shift06 1197/1197 rows |

## The differential harness (`cmd/port-parity`)

Design: snapshot identical inputs into `parity_legacy` +
`parity_go` sandbox schemas → run the legacy PL/pgSQL via
`search_path` → run the Go port's statements (schema-parameterized) →
FULL JOIN diff with tolerances. `-emit` renders the entire run as a
psql script **from the same Go constants the worker executes**
(single-source: you verify the port, not a transcription).

Subjects: `recalc`, `compute`, `hour`, `day`, `shift`. Run pattern:

```
go run ./cmd/port-parity -subject hour -emit > parity-hour.sql
# transport (base64 → docker cp), then on the DB host:
docker exec -i timescaledb psql -U postgres -d packiot -tA \
  -v ON_ERROR_STOP=1 -f /tmp/parity-hour.sql
# verdict line: <mismatches>|<compared>
```

Long legacy legs: run detached (`nohup … > /tmp/parity-X.out`), never
two concurrently (they DROP/CREATE each other's schemas).

### The five artifact classes (mismatches that are NOT bugs)

Learned on the first subject's six-iteration shakedown; every guard is
now built into the emitted scripts:

| Class | Tell | Guard |
|---|---|---|
| Boundary racers (`now()` in re-flag windows) | mismatching rows change every rerun | epsilon ≥ the slower leg's runtime |
| Eligibility-window edges | row admitted by one leg only | exclude an edge band |
| Open-row time drift | Δ ≈ the inter-leg gap exactly | compare closed rows only |
| Float summation order | relative Δ ~1e-7 at big magnitudes | relative tolerance |
| Environment | timeouts / plan differences | pre-index snapshots; serialize runs |

And one real-bug archetype it caught: **PL/pgSQL `IF FOUND` after an
aggregate `SELECT INTO` (no GROUP BY) is ALWAYS true** — prod zeroes
and clears no-data rows; a naive inner-join port skips them. With
GROUP BY it's genuinely conditional. Port each verbatim.

## The bake comparator (ADR-0016 §6.1)

Runs every 10 minutes since the 10.9 cutover made all flows
same-reality by construction:

- **Fidelity** (legacy F1 vs Go F2): 10 surfaces — PO runtime, shift/
  hour/day grains, UNS hour/week/month/job, closed-event ends, pool
  presence. Closed windows only; drift classes excluded structurally.
- **Identity** (Go F2 vs Go F3): aggregate fingerprints
  (`count|sums`) that must be EQUAL — any 1 is a real divergence in
  the dual-emit path.

**Reading discipline** (printed on the dashboard itself): every
non-zero needs a named cause; persistence past a documented expiry is
the signal. The flip gate is 7 consecutive green days.

## Rules of engagement (hard-won, enforced)

1. **Call-site verify before porting** — the dispatcher's `perform()`
   is truth; names and monitor logs lie (4 dead generations dodged).
2. **prod DB is SELECT-only, always** (`BEGIN READ ONLY`, awslambda
   role). All fixes/DDL go to staging.
3. **Measure writes, not flags** — `recalc_needed=true` is the steady
   state of live buckets (tails re-flag by design).
4. **Instrument before theorizing** — silent fail-opens get Warn
   logs first; then diagnose.
5. Every mismatch gets a class or it's a bug — "N mismatches,
   unexplained" is a failing port.
