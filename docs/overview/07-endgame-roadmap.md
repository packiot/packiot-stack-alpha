# 07 — Endgame roadmap: from today to the fully-migrated stack

- **Written**: 2026-07-07. **Owner**: Emmanuel Podestá.
- **What this is**: the ONE sequenced plan from the current state to
  the finish line — a single consolidated flow, split Go services on a
  hardened RabbitMQ bus, an enterprise-grade database, production
  migrated, legacy decommissioned. Written to be picked up cold by any
  engineer or AI session ("the continuator") — see §Handoff at the end.
- **Companions**: `06-state-and-continuation.md` (live state — always
  trust it over this doc's status column), ADR-0017 (the target
  architecture this roadmap executes), `adr/reference/
  0012-phase5-prod-readiness.md` (gate board G1–G8),
  `adr/reference/0016-flip-runbook.md` (Phase A's script).

## The finish line (definition of done)

1. ONE database (`packiot_shadow`, promoted), schema at
   `0016-endstate-schema-map` + `0012-naming-map` shape, pools
   complete, `ca_*` CAggs compressed, retention policies live.
2. FOUR first-party services (ingest-worker, engine-worker,
   reports-worker, refdata-api) + edge-transformer per factory, each
   least-privilege, independently deployable, with SLOs and alerts.
3. RabbitMQ as the only data-plane bus (quorum queues, confirms,
   idempotent consumers); MQTT/SparkPlug as the only factory ingest.
4. Production runs this stack; EB edge-api, GCP PubSub, both Node-RED
   pairs, shadow-mirror, Hasura (pending #86): all retired.
5. Backups restore-drilled; on-call runbooks exist; the 260-bug
   journal's rules are encoded in CI gates, not memory.

## Phase map (A → F sequential; G continuous)

```
A. Flip week          B. Stabilize (30d soak)   C. Hasura endgame
   now → ~07-14          07-14 → ~08-14            08-01 → +4-6 wks
        │                     │                        │
        └──────► D. Schema endgame ◄───── (C unlocks naming wave)
                      │
                 E. Process split (ADR-0017)
                      │
                 F. Production migration (Phase 5) → factory rollouts
G. Enterprise hardening — runs alongside B-F (alerts, backups, security)
```

---

### Phase A — Flip week (NOW → ~2026-07-14)

*Entry*: today. *Exit*: staging runs ONE flow; 30-day freeze started.

| # | Item | Who | Status |
|---|---|---|---|
| A1 | shift-resolver close-out | done | ✅ EARLY (2026-07-06, same-row evidence 0/46): trigger DROPPED on staging, Go fill live on all flows (verified 07-07) |
| A2 | 7-day bake window completes; every 09-board non-zero has its named cause | clock + daily human glance | ⏳ ~07-13 |
| A3 | sap13 72h bake green (`jobs_ticks_total{job="sap13"}`, zero errors) | clock | ⏳ started 07-06 23:15Z |
| A4 | G3: PowerBI sign-off checkbox (evidence already generated) | **human** | 🔴 deferred by owner |
| A5 | Execute `0016-flip-runbook.md` (~30 min, env-reversal rollback) | human-supervised session | blocked on A1–A4 |
| A6 | Same day: capture Wave-4 soak baseline (`0012-wave4-contract.sql` §A) | model | blocked on A5 |
| A7 | Retirements R1–R3, R5–R7, R9 (compose/env/code removals; R4/R8 wait for freeze expiry) | model, one PR each | blocked on A5 |
| A8 | Post-flip verification hour (runbook §last) + `guides/manual-smoke-check.md` full pass | model | blocked on A5 |

Risks: a late 09-board non-zero without a named cause → bake clock
restarts for that surface (do NOT flip over an unexplained delta).

### Phase B — Post-flip stabilization (flip → +30 days)

*Entry*: A done. *Exit*: 30-day soak clean; alerting live; old DB
freeze expiry executed.

- B1. **Alert rules — DONE 2026-07-07** (`monitoring/prometheus/rules.yml`:
  scrape-down, engine error streak, engine stalled, ingest silent,
  write-path dry). Open human choice: push routing (Alertmanager →
  ntfy/email) — wire only when someone commits to reading it.
  Backlog: CAgg-invalidation + disk + queue-depth rules need a
  postgres/rabbitmq exporter first (G-track).
- B2. Golden fixtures + auto bake-panels (session-77 methodology
  leftovers #3/#6) — cheap now, priceless during E and F.
- B3. Watch items from 06 §5 (site_hour bucket timing, sim OEE>1
  calibration) — fix or ledger them.
- B4. At soak expiry: Wave-4 §B preflight → §C/§D contract drops
  (needs the PRODT `LLLLL` ticket closed for hygiene symmetry) + R4/R8
  (EBS snapshot first).
- B5. Backup baseline: pgBackRest/wal-g decision + first PITR restore
  drill on a scratch instance (G-track, but start here).

### Phase C — Hasura endgame (query-log closes 2026-08-01)

*Entry*: 30-day query log complete + prod Hasura creds (gate G6).
*Exit*: task #86 decided; if "retire": front4 reads via refdata-api,
Hasura containers removed (R5 completes).

- C1. **Staging surface: DONE** — 12h log = 10 root fields, sole
  consumer edge-node-red, staging Hasura already de-bloated to that
  set, and **refdata-api covers 10/10** (verified 2026-07-07). Prod
  Hasura Cloud enumeration still wants working creds (stored secret
  401s as of 07-07) — but prod's consumer is front4, which is Phase F
  scope; staging retirement does NOT wait for it.
- C2. Decision with product: retire vs keep-minimal. The audit
  (4% utilization) predicts retire; the plan assumes it.
- C3. **The one remaining staging step**: flip edge-node-red's
  GraphQL tab to HTTP against refdata-api (submodule flow surgery —
  mind the flow-manager dual-file lesson; do it in a fresh session
  with a bake window), then drop `hasura`/`hasura-init` (R5). This is
  the TOP UNBLOCKED item after the flip.
- C4. **This unlocks the naming wave** (D3): renames stop paying the
  165-table re-tracking tax.

### Phase D — Schema endgame (interleaves with C)

*Entry*: flip done. *Exit*: staging DB matches the endstate map.

- D1. CAgg consolidation on the consolidated DB: retire remaining
  `agg_*`/`ca_agg_*` dialects → `ca_*`, enable compression, retention
  policies per table class (raw 90d / grains 2y / hist frozen).
- D2. Pool completion: remaining per-customer families from the
  naming-ledger (`equipment_boxes_cust_13` → `customer_reports.boxes`
  etc.) — expand-contract, PowerBI gate re-run per wave.
- D3. **h_*/v_* naming wave** (sandbox-proven in `0012-naming-map.md`;
  gated on C4): on the real DB the h_* are function return types —
  ALTER FUNCTION in lockstep; compat views for every name; gate green
  before contract.
- D4. Per-service DB roles — SQL PREPARED
  (`adr/reference/migrations/0017-service-roles.sql`); apply at Phase E
  when each service gets its own secret; verify with the
  privilege-escalation test (each service MUST fail outside its grants).

### Phase E — Process separation (ADR-0017; only after the flip)

*Entry*: B done (stable single flow + alerts) **+ ADR-0017 blessed
by the decider** (it is Proposed — a human call, not a default).
*Exit*: monolith retired; four services with independent deploys and SLOs.

- E1. Extract **reports-worker** first (lowest risk, cleanest seam:
  `internal/reports` + jobs plumbing). Shared module (`services/pkg/`)
  is born here — move, don't fork.
- E2. Short differential bake: split services vs monolith on mirrored
  input → byte-identical writes (the port-parity discipline applied to
  topology).
- E3. Split **engine-worker** (rollup/uns/events/shiftresolver/
  pocontrol + advisory-lock leader lease) from **ingest-worker**
  (amqp/handlers/sparkplug/writers/tenants).
- E4. RabbitMQ hardening: quorum queues, per-consumer-group
  retry/DLX (pattern exists — replicate), queue-depth alerts.
- E5. SLOs: ingest p99 write latency + freshness; engine tick success
  rate; reports completion windows. Wire to B1's alerting.
- E6. Failure-injection afternoon: kill each service under load,
  verify blast radius matches ADR-0017's table. Document in runbooks.

### Phase F — Production migration (Phase 5 of ADR-0012 / "Phase VI")

*Entry*: gate board G1–G8 all green + one full month-boundary cycle
green on staging. *Exit*: prod runs the new stack; legacy retired.

- F1. Prerequisites (all prepared, all human-gated): G6 creds, G7
  factory payload capture, G8 `migration_role`, customer sign-offs.
- F2. Execute the knex series 1–5 from
  `0012-phase5-prod-readiness.md` §2 — pool DDL + backfill (prod HAS
  data), writer cutover with ≥72h bakes per family, façade flips per
  customer group, CAgg adoption (75GB invalidation fix FIRST), Wave-4
  contract after prod's own soak.
- F2b. **Incoplast-class prerequisites (ADR-0019)**: edge command
  channel (G4) + client.yaml v1.1 (database integration, S7 rack/slot,
  ERP dims, edge-operator mode) + credential externalization for
  customer ERP secrets — REQUIRED before any factory with a local
  operator UI or ERP coupling cuts over. CPACK-class factories are
  unaffected.
- F3. Factory-by-factory MQTT cutover (edge-transformer to real
  factories; the 10.9 pattern, one factory at a time, G7's capture as
  the validation corpus).
- F4. Legacy decommission: EB edge-api env, GCP PubSub, prod
  oeecloud-node-red, prod pg_cron piot_* engine — each behind its own
  30-day frozen-read window, EBS snapshot before every drop.

### Phase G — Enterprise hardening (continuous backlog, start anytime)

Security: mosquitto auth/ACL (ADR-0011 P0-2b), secrets rotation
schedule, authentik in front of every UI. · Ops: on-call runbook per
service, DR runbook + quarterly restore drill, capacity model (today:
~250 rows/15min — headroom math for 10× factories). · Quality: CI
gates encoding the golden rules (SELECT-only lint on prod DSNs,
consumer-idempotency checklist as PR template check, naming-ledger
lint banning tenant literals in new code). · Load test: simulator at
50× tick rate against staging, find the first bottleneck before a
customer does.

---

## §Handoff — for the next session/model that picks this up

**Read order (30 minutes to full context):**
1. Project memory `plan_endgame_migration.md` + `MEMORY.md` index
   (Claude project memory) — machine state + this plan's live status.
2. `docs/GUIDE.md` — the stack, end to end.
3. `docs/overview/06-state-and-continuation.md` — live snapshot;
   **trust it over every status column in this file**.
4. This roadmap → find the current phase → pick the topmost unblocked
   item. Human-gated items (G3–G8): prepare, ping, never improvise
   around them.

**The rules that prevent disasters** (long-form: `05-onboarding` §Day 2,
`PORTING.md`, the 260-entry bug journal):
- Prod is SELECT-only, always — `BEGIN READ ONLY`, no exceptions,
  the role won't save you (discipline is the guardrail).
- Call-site-verify before porting or deleting anything (dead
  generations; the "back4-api writer" that turned out to be a reader).
- One precise predicate per destructive cleanup; capture baselines
  before drops; EBS snapshot before anything irreversible.
- One bake at a time; every 09-board non-zero keeps a named cause;
  clocks cannot be compressed (they sample time-structured variation).
- Expand-contract with a façade for EVERY renamed name
  (Hasura/PowerBI read names); gate re-run after every wave.
- New code: no tenant literals, config triplets per job, verbatim-first
  ports with fidelity-guard tests.

**Ops crib**: app EC2 `i-06c9547a2c7091ab7`, DB EC2
`i-064bb36d1c454d861` (SSM); heavy SQL via `scripts/ssm-psql.sh`
pattern; git: `git fetch && git checkout -B <branch> origin/staging`;
`staging` is PR-only (required check "Validate compose files");
smoke triage: `docs/guides/manual-smoke-check.md`.
