# oeecloud-worker

**The engine.** Consumes the normalized telemetry stream off RabbitMQ
and hosts every scheduled computation that the legacy stack ran as
pg_cron PL/pgSQL — runtime rollups, PO lifecycle math, UNS refreshers,
per-customer report writers. If a number in the product came from a
`piot_*` function on prod, its Go replacement lives here (ADR-0014;
name mapping: `docs/adr/reference/naming-ledger.md`).

## How it works

Two independent halves in one process:

1. **AMQP consumer** — binds `oeecloud-worker-q` to the `oee` topic
   exchange, parses envelopes, batches per-table writes into ONE pgx
   round-trip per delivery. Routing by `source_type`: `""` → main pool
   (F1), `"go"` → `shadow_go_port` schema, `"refactored"` → the shadow
   DB pool (F3, `POSTGRES_SHADOW_DB_NAME`).
2. **Scheduled jobs** — `internal/jobs.Loop` (ticker + panic recovery
   + per-tick timeout + boot stagger). Every job is a goroutine wired
   in `cmd/oeecloud-worker/main.go`, gated by an env flag, observed via
   `jobs_ticks_total{job,outcome}`.

## Code map

| Package | Role |
|---|---|
| `amqp`, `handlers`, `sparkplug`, `writers`, `tenants` | consume → resolve topic → batch-write path |
| `jobs` | the scheduler primitive every job runs on |
| `flows` | `flows.Standard(pool, shadowPool)` — the dual-destination fan-out jobs write through |
| `rollup` | runtime grain cascade (hour/day/shift/week/month × equipment/area/site) + PO recalc dispatcher |
| `pocontrol` | PackML 30800-series PO lifecycle |
| `events` | equipment-events deriver (ADR-0014 P3a) |
| `shiftresolver` | Go port of the shift-fill trigger (ADR-0014 P2) |
| `uns` | UNS current-state provisioner + refresh matrix |
| `reports` | per-customer writers: speed33, shift06, sync06, sap13, boxes (+ bridge) — ADR-0012 Wave 2 |
| `bake` | side-by-side comparator (ADR-0016 §6.1) — off post-flip |
| `config`, `secrets`, `db`, `metrics`, `log`, `health` | plumbing (creds from AWS Secrets Manager, not env) |

## Config conventions (the rules new jobs follow)

- **Triplet per job**: `X_ENABLED` / `X_INTERVAL_MINUTES` / ids —
  every job ships disabled by default; compose flips it per env.
- **No tenant hardcodes in new code** — enterprise/customer ids come
  from config (`SPEED33_CUSTOMER_ID`, `PO_RECALC_EXCLUDED_ENTERPRISES`,
  …). Verbatim-embedded legacy SQL may contain frozen literals, marked.
- DB uses `QueryExecModeSimpleProtocol` (pgbouncer transaction pooling
  compatibility) — do not remove.

## Run / test

```bash
go build ./... && go test ./...          # unit + port-fidelity guards
go run ./cmd/port-parity -subject hour -emit > parity-hour.sql   # differential harness
```

Local: runs inside `make up` (see repo README). Staging: deployed by
push to `staging`; flags live in `compose.staging.yml`.

## Invariants

- **Ports are verbatim-first** (`docs/PORTING.md`, all nine steps);
  fidelity-guard tests pin business rules and amber bugs — a test
  failing because you "fixed" legacy behavior is working as intended.
- Value guards reject |v| > 1e12 / NaN / Inf (post-oscillator,
  loss-with-alert) — never bypass.
- One bake at a time; a new job enables only when the previous bake
  surface is quiet.
