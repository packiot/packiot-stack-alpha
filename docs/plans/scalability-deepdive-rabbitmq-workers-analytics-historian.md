# Scalability deepdive — RabbitMQ · workers · analytics DB · historian DB

## Why now
The Bispharma end-to-end deepdive proved the *correctness* of the pipeline. This
follow-up asks the orthogonal question: **what breaks first when load grows?**
A baseline probe (`scripts/scalability-probe.sh`, run 2026-09-22) already surfaced
the candidate ceilings — this plan turns that snapshot into a load-tested, evidence-
backed capacity model with concrete remediations.

**Baseline (staging, near-idle) — the numbers that frame every hop below:**
| Dimension | Observed | Ceiling | Distance |
|---|---|---|---|
| analytics DB connections | **49** (analytics 24 · superset 14 · packiot 3 · pg 2) | **50** | **98% — binding constraint** |
| worker replicas | stream-engine ×1, sparkplug-agent-shared ×1, read-api ×1, edge-api ×1 | — | **all singletons (SPOF + no h-scale)** |
| RabbitMQ main queues | 1 consumer each (`stream-engine-q-*`), 0 backlog | 65k conns / 3.27 GB mem | huge headroom |
| worker mem caps | agent 192 MB (12%), stream-engine 256 MB (10%) | hard `mem_limit` | tight caps, low current use |
| bronze `equipment_values` | 1316 MB (+ raw 1300 MB) | disk / retention | growth driver → historian (#280) |
| top throughput tenant | **ent5 (bispharma twin) 1962 rows/10min** > cpack 1179 ≈ sbx 1179 | — | twin dominates staging load |

## Guardrails (same doctrine as the Bispharma deepdive)
- **Read-only by default.** The probe and every hop below only `SELECT` /
  `list_*` / `stats`. Any config change (raise `max_connections`, add a replica,
  add pgbouncer) is a **separate, explicitly-approved** step — several touch prod.
- **Prove by running, never by HTTP-200 / green-build.** Capacity claims must come
  from a measured ceiling and a measured distance to it, not from "looks fine".
- **Staging ≠ prod ceilings.** Confirm each ceiling on prod before concluding —
  `max_connections`, `mem_limit`s, and retention windows may differ.

## Hops

### S1 · Analytics DB connection ceiling *(the binding constraint)* — ✅ probe-provable
- **Instrument:** `scalability-probe.sh` §3 + `pg_stat_activity` breakdown by
  `datname` / `application_name` / `state`.
- **Questions:** Who holds the 50? (superset pool = 14 — is that a fixed pool or
  per-request?) How many are idle vs active? Is pgbouncer in front of anything, or
  are these raw connections? What is prod's `max_connections`?
- **Load test:** drive N concurrent Superset dashboard loads + edge-api/read-api
  requests; watch `total_conns` approach 50 and observe the failure mode
  (connection refused vs queue). 
- **Remediations to cost out:** raise `max_connections` (cheap, RAM-bound ~ 9 MB/conn);
  put **pgbouncer** (transaction pooling) in front of the analytics DB — the
  proper fix, matches the edge-api→analytics path that *already* uses pgbouncer;
  cap the Superset SQLAlchemy pool.
- **PASS:** a documented headroom margin under realistic concurrency; **FAIL:**
  connection refusals reproduced under expected multi-tenant load.

### S2 · Worker fleet — singletons, replicas, and back-pressure — ✅ probe + code
- **Instrument:** `scalability-probe.sh` §1 + the compose `deploy.replicas` /
  `mem_limit` for each hot-path service; stream-engine's prefetch + concurrency env.
- **Questions:** Is stream-engine *stateless* (safe to run N replicas competing on
  the same queue) or does it hold per-tenant ordering state? Same for
  sparkplug-agent-shared (it owns tag-alias/rebirth state per tenant — likely NOT
  trivially replicable). What are the CPU/mem limits and are they right-sized?
- **Load test:** replay a high-rate SparkPlug window (scale the bispharma-twin rate
  up, or a dedicated load fixture) and watch stream-engine CPU + queue depth +
  consumer prefetch saturate. Find the single-consumer throughput ceiling (msgs/s).
- **Remediations:** competing-consumer scale-out for stateless workers (more
  replicas on the same per-tenant queue) vs sharded queues for stateful ones;
  right-size `mem_limit`s (current caps are tight but usage is low — confirm the
  cap is above the p99 working set, not the idle set).
- **PASS:** measured msgs/s per consumer + a scale-out story per worker;
  **FAIL:** a worker that can't scale and is already near its throughput ceiling.

### S3 · RabbitMQ — queue topology, fan-out, DLQ hygiene — ✅ probe-provable
- **Instrument:** `scalability-probe.sh` §2 + `list_queues` (messages, consumers,
  memory, message rates) + the exchange/binding topology (`oee` exchange, per-tenant
  routing keys, retry-30s + failed DLQs).
- **Questions:** Per-tenant queues scale linearly with tenant count — at 100 tenants
  that's 100×(main+retry+failed) = 300 queues; what's the per-queue overhead and the
  node ceiling? Are the retry/failed DLQs being drained or silently growing (cf. the
  legacy-replicator DLQ incident)? Is there a global publish/deliver rate ceiling?
- **Load test:** measure publish + deliver + ack rates under the S2 load; watch node
  memory vs the 3.27 GB high-watermark and file-descriptor/socket limits.
- **PASS:** headroom at projected tenant count + all DLQs at 0 or actively draining;
  **FAIL:** DLQ growth, or per-queue overhead × tenant-count approaching node limits.

### S4 · Historian (cold store) — growth offload + query cost — ⚠ partly gated on #280
- **Instrument:** `scalability-probe.sh` §4/§6 + the `equipment_values` growth rate
  (1316 MB now) vs the hot-retention window (silver values = 90d, events = 2yr) +
  the cold parquet/DuckDB gateway.
- **Questions:** At the observed ingest rate, when does hot `equipment_values`
  breach comfortable size? Is the cold-append watermark keeping pace (280k rows/day
  per the historian model)? What's the query cost of a cross-boundary
  (hot ∪ cold) read at scale, and does the #280 move-not-copy design remove the
  overlap-scan cost? Ties directly to the `reference_historian_*` memory + #280.
- **PASS:** cold offload keeps hot within retention + boundary reads stay bounded;
  **FAIL:** hot table growth outruns retention/offload, or cold union scans blow the
  read-api 20s timeout at projected volume.

### S5 · Synthesis — the capacity model + prioritized remediations
Produce a one-page "what breaks first, at what tenant/tag-rate multiple, and the fix"
table. Expected ranking from the baseline: **(1) DB connections (98% now) → pgbouncer/raise;
(2) worker singletons → replica/shard per statelessness; (3) hot-table growth → #280;
(4) RabbitMQ (comfortable, watch DLQ + per-tenant queue count).**

## The tool (instrument for every hop)
`scripts/scalability-probe.sh` — read-only, one-shot. Inputs (env): `PGPASSWORD`
(required), `APP_INSTANCE`, `PGHOST/PGDB/PGUSER`, `HIST_HOST`, `CONN_WARN_PCT` (80),
`SLOW_QUERY_S` (60). Emits PASS/WARN/FAIL per dimension. Run on the app box (SSM) or
relay. It is the repeatable baseline — re-run it before/after each remediation to
prove the ceiling moved.

## Out of scope
Front-end (front4/operator/csadmin) scaling, CloudFront/CDN, Cognito rate limits —
separate surfaces. This deepdive is the **ingest→store data plane**.
