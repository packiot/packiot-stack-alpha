# The Stack Guide — from PLC signal to PowerBI dashboard

- **What this is**: the single front door. One linear walk through the
  entire stack — the signal's journey, the environments, the code map,
  the modernization program, how to operate it, how to work on it, and
  a glossary. **It never re-explains what another doc owns; it routes.**
  If you find yourself reading the same topic twice in `docs/`, one of
  the copies is a bug — file it.
- **Convention**: structured after the `ARCHITECTURE.md` pattern
  (bird's-eye view + code map + invariants, kept stable) and the
  Diátaxis split (tutorial / how-to / reference / explanation live in
  different files — this guide is the map between them).
- **The other front doors**: [`../README.md`](../README.md) = run the
  local harness. [`INDEX.md`](INDEX.md) = full doc inventory with
  audiences. [`overview/05-onboarding.md`](overview/05-onboarding.md) =
  your first week, guided.

---

## 1. The problem (one paragraph)

Packiot answers "how efficiently is this factory running?" It ingests
machine telemetry from factory PLCs, tracks production orders, shifts,
downtimes, and computes **OEE** (Quality × Availability × Performance)
per machine / line / area / site, live. Customers consume it through
the product frontend, operator screens, and PowerBI reports reading
the database directly. This repo is the **modernized stack**: the
Node-RED + in-database-PL/pgSQL legacy rebuilt as Go services + Docker
Compose + a consolidated TimescaleDB, migrated incrementally and
*provably* (every step baked against the legacy behavior before the
legacy retires).

## 2. The signal's journey (beginning → end)

Follow one production count from the factory floor to a dashboard.
Each hop names its owner in code and the ONE doc that explains it.

```
 PLC ──SparkPlug B/MQTT──▶ edge-transformer ──AMQP "oee"──▶ oeecloud-worker ──SQL──▶ TimescaleDB
                                                                                        │ CAggs + jobs
 operator ◀── operator UI ◀── edge-api ◀───────── user_logs / control plane ────────────┤
 customer ◀── front4 (GraphQL) / PowerBI (ODBC façades) / Grafana ◀─────────────────────┘
```

1. **The machine speaks SparkPlug B.** A PLC publishes PackML-coded
   metrics (production counts, state, speed; parameter map in the root
   monorepo docs) over MQTT. In dev/staging a simulator plays the
   factory: `simulator/` (plc-sim). *Owner*: factory / `edge-node-red`
   submodule (legacy path). *Doc*: ADR-0010 (MQTT as THE ingest —
   executed 2026-07-06, "10.9 cutover").
2. **edge-transformer decodes and normalizes.** The per-factory Go
   service subscribes to MQTT, decodes SparkPlug, resolves topics to
   equipment, and publishes normalized envelopes to the RabbitMQ `oee`
   exchange (routing key `sparkplug.data.<tenant>`). It is also the
   **durability boundary**: store-and-forward outbox for intermittent
   factory connectivity. *Code*: `services/edge-transformer/` (the one
   service with its own README). *Docs*: ADR-0009 (why it exists),
   ADR-0011 (durability), `guides/edge-transformer-*` (historical
   phase runbooks).
3. **oeecloud-worker writes raw + runs the engine.** The cloud Go
   worker consumes the `oee` exchange and writes the raw tables
   (`equipment_values`, UNS current-state). It also hosts **the
   engine**: every scheduled job that the legacy ran as pg_cron
   PL/pgSQL — runtime rollups (hour/day/shift/week/month ×
   equipment/area/site), PO runtime compute/recalc, UNS refreshers,
   per-customer report writers (speed33, shift06, sync06, sap13,
   boxes). *Code*: `services/oeecloud-worker/` (`internal/jobs` is the
   scheduler; one package per engine family). *Docs*: ADR-0014 (why
   OEE math left the database), `overview/01` §4 (the job list),
   `adr/reference/naming-ledger.md` (legacy fn → Go job names).
4. **TimescaleDB stores and aggregates.** Raw hypertables → native
   hierarchical continuous aggregates (`ca_*`, 1min → 1hour) → runtime
   grain tables maintained by the engine. The schema itself is being
   refactored (pool multi-tenancy + façades preserving every
   PowerBI-facing name). *Docs*: ADR-0012 (pool + naming), 
   `adr/reference/0016-endstate-schema-map.md` (target shape),
   `overview/01` §3 (readable summary).
5. **The control plane flows through edge-api.** Operator actions
   (start/stop POs, manual events, downtime edits) hit `edge-api`
   (NestJS submodule), which writes the DB and the `user_logs` audit
   trail. During the migration, `shadow-mirror` replays those actions
   onto the shadow flow (retires at the flip, R1). *Docs*: ADR-0013,
   root monorepo CLAUDE docs for edge-api conventions.
6. **Consumers read three ways.** front4 via GraphQL (staging: Docker
   Hasura; prod: Hasura Cloud — under retirement review, task #86);
   PowerBI via ODBC against the **façade names** (the untouchable 37+1
   list: `guides/powerbi-gate-objects.txt`); Grafana dashboards for
   ops (`grafana/`, provisioned; `/d/bake-flow-parity` is the flip
   gate). refdata-api / query-api is the future customer-facing read
   surface (ADR-0015).
7. **Proof wraps every hop.** Nothing replaced the legacy without a
   differential: the port-parity harness (0/32,848 mismatches across
   the two core passes), the bake comparator (10 fidelity surfaces
   side-by-side), and the PowerBI gate harness. *Docs*:
   `overview/04-verification.md` (the method — read this before
   trusting any number), `PORTING.md` (the law you follow to add hop
   changes).

## 3. Three environments, one repo

| Env | What runs | Truth source |
|---|---|---|
| **development** | full local harness: `make up` — DB, RabbitMQ, MQTT, simulator, all services | `compose.development.yml` header + `../README.md` |
| **staging** | the real fleet on EC2 (app `i-06c9547a2c7091ab7`, DB `i-064bb36d1c454d861`), deployed on every push to `staging` | `compose.staging.yml` header + `overview/06` |
| **production** | legacy prod (packiot40 DB, EB edge-api) + the new prod stack in dry-run; migrates at Phase 5 | `compose.production.yml` header + ADR-0003 + `adr/reference/0012-phase5-prod-readiness.md` |

The compose file **header comments are the canonical per-environment
service maps** — they sit next to the code and stay current. Read them
before any diagram.

Repo boundary rule: `services/*` = stack-owned Go services, developed
here. `edge-api`, `edge-node-red`, `operator` = **git submodules**
(their own repos, canonical branch `staging`, auto-bumped by CI — see
`../CONTRIBUTING.md`). Never edit a submodule from this repo casually.

## 4. The modernization program (the plot)

The ADR spine tells the story; `overview/02-what-was-done.md` is the
narrated map. Compressed:

- **ADR-0009/0010/0011**: get ingest out of Node-RED into Go
  (edge-transformer), make MQTT the only ingest (done 2026-07-06),
  define the durability boundary.
- **ADR-0013/0014**: shadow the control plane; port ALL in-database
  OEE math to the Go engine, proven by differential parity.
- **ADR-0012**: fix the schema — pool multi-tenancy, façades, naming
  (Waves 0–4; Waves 0–1 done, Wave-2 code complete, Wave 3 partially
  flipped, Wave-4 contract prepared with soak preflight).
- **ADR-0016**: consolidate the parallel flows into ONE
  (`packiot_shadow` promoted at "the flip" — runbook prepared,
  `adr/reference/0016-flip-runbook.md`), then retire R1–R9.
- **Phase 5**: repeat on production, quarter-scale — gate board and
  full sequence in `adr/reference/0012-phase5-prod-readiness.md`.

Current live status is ALWAYS `overview/06-state-and-continuation.md`
(timestamped) — never trust a status line in any other doc, including
this one.

## 5. Code map (matklad-style: where's the thing that does X?)

| Path | Role | Invariant to respect |
|---|---|---|
| `services/edge-transformer/` | factory-side ingest: MQTT → decode → normalize → AMQP publish; outbox | the durability boundary (ADR-0011): factory data survives disconnects |
| `services/oeecloud-worker/` | THE engine: AMQP consumer + all scheduled jobs (`internal/jobs.Loop`) | every job is env-flag-gated; ports are verbatim-first (PORTING.md) |
| `services/shadow-mirror/` | control-plane replay: polls `user_logs`, re-applies to shadow flow | retires at flip (R1); cursor-based, idempotent |
| `services/mirror-worker-go/` | prod→staging mirroring + reconciler/comparator | prod side is SELECT-only, always |
| `services/refdata-api/` | read surface (ADR-0015 direction) | — |
| `edge-api/`, `edge-node-red/`, `operator/` | submodules (control plane, legacy factory flows, operator SPA) | edit in their repos; CI auto-bumps pointers |
| `compose*.yml` | the three environments | header comments are canonical service maps |
| `db/init/` | LOCAL-dev DB bootstrap only | never confuse with staging/prod schema (that's migrations + captures) |
| `simulator/` | plc-sim: SparkPlug traffic generator | staging OEE>1 artifacts come from sim calibration, not math |
| `grafana/`, `monitoring/` | dashboards + Prometheus stack | `/d/bake-flow-parity` is a FLIP GATE, not decoration |
| `scripts/` | operational tooling: sandbox reprovision, PowerBI gate harness, prod-read evidence | prod access = `BEGIN READ ONLY`, no exceptions |
| `terraform/` | infra as code (prod WIP) | — |
| `docs/adr/reference/captures/` | immutable legacy SQL captured from prod | NEVER edit — it's evidence |
| `docs/adr/reference/migrations/` | as-executed / prepared migration SQL | single-shot files say so in their headers |
| `tests/` | integration harness | `make test-integration` |

Undocumented-service note: only edge-transformer has a README today;
the one-paragraph roles above are the interim tour (gap tracked in the
doc-review, 2026-07-06).

## 6. Operating the stack (how-to routes)

- **Anything live right now?** → `overview/06` §fleet + Grafana.
- **Something smells wrong / post-deploy check** → `guides/manual-smoke-check.md`
  (hop-by-hop layers 0–5).
- **Deploy** → push to `staging` (CI does the rest; `../CONTRIBUTING.md`).
  Prod deploys are gated (ADR-0003, OIDC).
- **Touch the staging/prod DB** → SSM into the DB EC2; heavy SQL via
  the base64→`docker cp`→`psql -f` pattern (`scripts/ssm-psql.sh`).
  Prod: `BEGIN READ ONLY` under the `awslambda` role, SELECT-only,
  always — the role does NOT structurally prevent writes; discipline
  is the guardrail.
- **Execute the flip** → `adr/reference/0016-flip-runbook.md` (~30 min,
  env-reversal rollback, 30-day old-DB freeze).
- **Run the PowerBI gate** → `scripts/test-powerbi-compatibility.sh`
  (report lands in `docs/powerbi-compat-report.md`); prod-read
  fidelity evidence → `scripts/powerbi-evidence-prod-read.sh`.
- **Rebuild the design sandbox** → `scripts/reprovision-refactor-sandbox.sh`
  (`packiot_refactor` on the DB EC2; disposable, reproducible).
- **Port something from PL/pgSQL** → `PORTING.md`. All nine steps.
  Capture the dispatcher first (dead-generation rule: the generation
  an orchestrator NAMES is not always the generation that WORKS).

## 7. Working here (the dev loop)

1. Clone with submodules; `make up` (harness details: `../README.md`).
2. Branch from `origin/staging` (`git fetch && git checkout -B feat/x
   origin/staging`). `main`/`master` are not the integration branches
   here — `staging` and `production` are.
3. Code. For engine work: one package per family in
   `services/oeecloud-worker/internal/`, env-flag the job, follow the
   config triplet pattern (`X_ENABLED` / `X_INTERVAL_MINUTES` / ids
   from config — never hardcode a tenant).
4. Test: `go test ./...` in the service; golden/parity harnesses per
   `overview/04`; `make test-integration` for the harness.
5. PR to `staging` (protected: PR-only + compose-validation check).
   Port PRs carry the PORTING.md checklist; MQ-consumer PRs carry
   `consumer-idempotency-checklist.md`.
6. Read `BUSINESS-RULES.md` before touching hierarchy/shift/OEE
   semantics — the rules there were paid for with incidents.

## 8. Glossary (the missing decoder ring)

| Term | Meaning |
|---|---|
| **OEE** | Overall Equipment Effectiveness = Availability × Performance × Quality |
| **SparkPlug B** | MQTT payload spec the PLCs speak; PackML parameter IDs ride it |
| **PackML** | machine-state model; parameters 30700–30899 control config + POs |
| **tp_equipment** | 1=machine, 2=sector, 3=line |
| **lead machine** | the machine whose events stand for a whole line/sector |
| **Flow 1 / F2 / F3** | legacy staging flow / Go shadow flow / consolidated target flow |
| **triple-emit** | edge-transformer publishing the same data to legacy + go + refactored paths during migration (collapses at flip) |
| **source_type** | envelope field routing a message to its flow ("" legacy, "go", "refactored") |
| **shadow-mirror** | the control-plane replayer (user_logs → shadow DB); retires R1 |
| **bake / bake comparator** | running old + new side-by-side and diffing surfaces for N days before trusting the new |
| **amber bug** | a LEGACY bug deliberately preserved in the port (pinned by a test) until a consumer signs off on fixing it |
| **artifact classes** | the five kinds of parity mismatch that are NOT bugs (`overview/04`) |
| **dead generation** | a function version an orchestrator references that no longer executes; porting it is wasted/misleading work |
| **verbatim embed** | port archetype: the legacy SQL body embedded unchanged in Go, orchestration only rewritten |
| **port-parity harness** | `cmd/port-parity`: legacy vs Go on identical inputs, FULL JOIN diff |
| **pool pattern / façade** | one table with `customer_id` + per-customer views preserving legacy names (ADR-0012) |
| **Waves 0–4** | schema-refactor sequence: parity repair → expand pools → writer cutover → view flips → contract (drops) |
| **the flip** | promoting `packiot_shadow` to THE database, single-flow (0016 runbook) |
| **R1–R9** | the retirement list executed after the flip |
| **freeze window** | 30 days of read-only old-DB after the flip = the undo horizon |
| **CAgg** | TimescaleDB continuous aggregate; canonical prefix `ca_*` |
| **UNS** | unified-namespace current-state tables (`uns_*`), refreshed by the engine |
| **recalc_needed** | the dirty-flag cascade driving incremental OEE recomputation |
| **packiot40 / tsp12** | the production database (tsp12 is its legacy label) |
| **packiot_shadow / packiot_refactor** | live-data POC DB (future canonical) / disposable schema-design sandbox |
| **Hasura parity stub** | `17-hasura-metadata-parity.sql` — the effective list of prod-Hasura-tracked relations |
| **37+1 / PowerBI gate** | the enumerated PowerBI-facing objects (29+1 concrete names) × 5 test dimensions that gate every schema change |
| **naming ledger** | legacy name → clean refactored name contract (`adr/reference/naming-ledger.md`) |
| **golden rules** | prod SELECT-only · call-site-verify before porting · one precise predicate per destructive cleanup |

## 9. Which doc do I read? (the routing table)

| You want… | Read |
|---|---|
| to run it locally | `../README.md` + Makefile |
| the 10-minute program pitch | `overview/00` |
| the architecture | `overview/01` (+ compose headers for per-env truth) |
| the story of what happened | `overview/02` → ADRs it cites |
| "is X a bug or a decision?" | `overview/03` (the differences contract) |
| to trust the numbers | `overview/04` |
| your first week | `overview/05` |
| what's live/remaining RIGHT NOW | `overview/06` |
| to change code | §7 above → `PORTING.md`, `BUSINESS-RULES.md`, `TOPICS.md` |
| to execute the cutover | `adr/reference/0016-flip-runbook.md` |
| prod migration | `adr/reference/0012-phase5-prod-readiness.md` |
| everything else | `INDEX.md` (the full inventory) |

*Maintenance rule (matklad): this guide describes what changes rarely.
If editing it more than ~monthly, the content belongs in `overview/06`
or a specific doc — move it, and keep the route here.*
