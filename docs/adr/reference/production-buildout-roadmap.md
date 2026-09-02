# Production Build-Out Roadmap — from dry-run shell to first-client-ready

**Status:** Plan / design only — DESIGN, NOT EXECUTION. Nothing here promotes, deploys,
or mutates production. Execution happens deliberately, step by step, after USER review.
**Date:** 2026-07-27 · **Scope:** the *new* production stack (`packiot-stack-alpha`, `production` branch / EC2 `i-02d255a1c21fb1da3`). The legacy EB prod (`edge.api4.packiot.com`) is out of scope and untouched.
**Decision owner:** tech-lead (pending USER sign-off).

**Anchors:** [ADR-0003](../0003-production-deployment-parent-stack.md) (prod deployment — this
roadmap *revises* its DB decision, see §3.1), [ADR-0032](../0032-collapse-to-single-flow-f3.md)
(F3 collapse — prod skips the collapse and is born F3-native), [ADR-0042 P1](../0042-cpack-tee-frontdoor.md)
(CPACK ingest front-door — the prod-ingest template), [ADR-0042](../0042-separated-edge-gateway.md)
(separated edge gateway), [ADR-0016](../0016-staging-consolidation-master-plan.md) (the end-state
schema prod adopts from day one).

---

## 0. TL;DR — the critical path

```
W0  Decisions (fresh F3-native DB · re-cut branch · stay Compose)      ← BLOCKS everything
        │
        ▼
W1  Stack promotion / compose parity  ──────────────┐   THIS-WEEK-STARTABLE
    (re-cut production from staging; add the 8       │   (PR: compose-parity + secrets scaffold)
     migrated services; provision F3 schema; secrets)│
        │                                            │
        ├──────────────┬──────────────┬──────────────┤
        ▼              ▼              ▼              ▼
W6 Infra sizing   W2 Ingest      W3 Read plane   W4 PO path
   (split DB EC2)     front-door     (refdata +      (operator-adapter /
   THIS-WEEK          (nginx+SG+     front4 re-       operator write)
   (terraform PR)      mosquitto)     point) ⚠RISK
        │              │              │              │
        └──────────────┴──────┬───────┴──────────────┘
                              ▼
                W5  Parity / bake window  ← GATE before customer-visible flip
                              ▼
                      First client cutover (own program, own sign-off)
```

**The one-sentence plan:** re-cut `production` from `staging` to erase the 568-commit
gap, bring the eight migrated services into `compose.production.yml`, give the box a
*fresh single-flow F3-native database* (no legacy 3-flow baggage — greenfield prod
is born in the end-state staging is painfully migrating toward), stand up a per-client
mTLS ingest front-door, re-point the read plane, split the DB onto its own right-sized
instance, then bake one client's real data behind the scenes before anyone sees it.

**Two things are genuinely startable this week** (both low-risk, PR-only, no prod mutation):
1. **Compose-parity PR** — add the 8 absent services + missing secret references to
   `compose.production.yml` (config only; not deployed).
2. **Prod ingest + DB-split terraform PR** — the SG rule + mosquitto/agent front-door
   and the reserved `10.20.10.0/24` private-subnet DB EC2 (plan/`terraform validate` only,
   no `apply`).

**Three biggest risks:** (1) the **front4 read-plane re-point** (a consumer cutover that
can blank customer dashboards if the F3 read surface isn't complete first), (2) **DB sizing**
— `t4g.medium` with a *local* TimescaleDB container will swap and die under a real client
(staging already did), (3) the **empty-DB fresh-start** requires assembling the F3 schema
DDL correctly or the whole compute chain produces wrong OEE silently.

---

## 1. Where new-production is today (verified ground truth)

| Fact | Detail |
|------|--------|
| Branch | `production`, **FROZEN 2026-06-29, 568 commits behind `staging`** |
| Compute | single EC2 `i-02d255a1c21fb1da3`, `t4g.medium` (2 vCPU / 4 GB, arm64/Graviton), 64 GB gp3, us-east-1c |
| Orchestration | Docker Compose (`compose.production.yml`), **not** k8s/argocd — per ADR-0003 |
| Deploy | push `production` → self-hosted arm64 runner on the EC2 → `docker compose … up -d --wait --remove-orphans`. Submodules fetched: **edge-api + operator only** |
| DB | **local empty TimescaleDB container** (`timescale/timescaledb:2.25.2-pg16`), Hasura has **no metadata** (init is a no-op), knex migrations run against it |
| Services present (24 blocks) | postgres · pgbouncer · rabbitmq · hasura(+init) · db-migrate · edge-api · oeecloud-worker (**idle — no publisher**) · operator · grafana · loki · promtail · prometheus · authentik(server/worker/redis) · adminer |
| Ingest | **none** — SG opens only 22/80/443; no 5671/8444/8447; no broker exposed |
| Read plane | **none** — no refdata-api; front4/operator prod read legacy Hasura Cloud (`gqlpiot.packiot.com`) / back4 |
| DNS/TLS | `prod.packiot.app` child zone live; wildcard `*.prod.packiot.app` cert via Route53 DNS-01; per-service A→EIP; `auth.` vhost. **No** `amqp.`/`mq.` records |
| Secrets (`packiot/production/*`) present | db · hasura · app · nginx-auth · authentik · github-runner · ec2-rescue |

### 1.1 Services ABSENT vs `compose.staging.yml` (what promotion must bring)

**Data-plane (BLOCKERS — no telemetry without these):**
`edge-transformer` (SparkPlug decode + Go Calc → F3), `mosquitto` (internal MQTT broker),
`ingest-shim` (Incoplast-style HTTPS republish front-door), `oeecloud-worker` **has no
upstream** until edge-transformer + a broker exist.

**Read/PO-plane (BLOCKERS for a usable product):**
`refdata-api` (+ its `app-redis` cache), `operator-adapter` (Incoplast-style PO tee),
`shadow-mirror` (operator-action carrier — *may be unnecessary in greenfield prod*, see §5).

**Deliberately excluded (correct to keep out):**
`plc-sim`, `sparkplug-agent-cpack`(+`s7-softplc`/`s7-reader`), `mirror-worker-go`
(no upstream to mirror — prod IS the source), `edge-nodered` (per-factory, ADR-0005).

**Observability extras (nice-to-have, not blockers):** `tempo`, `alertmanager`,
`blackbox-exporter`, `cadvisor`, `node-exporter`, `postgres-exporter`, `redis-exporter`,
`barcode-service`.

---

## 2. Missing secret scaffolding (Secrets Manager gap)

`compose.production.yml` already references `packiot/production/rabbitmq-oeecloud-creds`
("not yet provisioned — worker startup will retry"). Promotion adds more. These must be
created in `terraform/production/secrets.tf` before the services can boot healthy:

| Secret | Needed by | Notes |
|--------|-----------|-------|
| `packiot/production/rabbitmq-oeecloud-creds` | oeecloud-worker | already referenced, **not provisioned** |
| `packiot/production/rabbitmq-edge-transformer-creds` | edge-transformer, ingest-shim | publish-perm user on `oee` exchange |
| refdata query keys + IdP config | refdata-api | `QUERY_API_KEYS` per-tenant; Cognito/Firebase issuer+client-id (public, not secret) |
| `INGEST_API_KEY` / `X-Ingest-Key` | ingest-shim, sparkplug-agent | per-client ingest auth |
| operator-adapter creds | operator-adapter | `OPERATOR_API_KEY` + the enterprise `api_key` |
| ingest TLS cert/key | ingest-shim / operator-adapter | mounted from host `/opt/packiot/*/certs` |

---

## 3. The three anchoring decisions (W0 — do these first, they shape everything)

### 3.1 DECISION: prod gets a FRESH single-flow F3-native database (revises ADR-0003)

**Recommendation: build prod's DB fresh, single-flow, F3-native — do NOT connect to the
legacy prod TimescaleDB, and do NOT replicate staging's 3-flow topology.**

ADR-0003's original decision was "new prod stack connects to the *existing* prod
TimescaleDB read-only, as a shadow." That premise assumed we were migrating an
**existing** customer already living in `tsp12`. That is not this situation:

- **Prod is greenfield.** The first client's data does not exist in `tsp12` — there is
  nothing to shadow or read-only-mirror. The shadow-replica rationale evaporates.
- **`tsp12` carries the baggage prod should never inherit** — the legacy F1 `public`
  schema, F2 `shadow_go_port`, pg_cron/trigger OEE compute, the comparator schemas.
  Connecting to it drags all of that into a brand-new environment.
- **F3 is the end-state.** Staging is spending ADR-0016/0032 *painfully migrating* toward
  `packiot_shadow` (Go-owned shift resolver, app-side OEE math, `ca_*` caggs,
  `customer_dashboards`). Greenfield prod can simply *be born there* — skip the collapse
  entirely. There is no F1/F2 to retire because they never exist.

**Concretely:** prod runs ONE database whose `public` schema *is* the F3 schema (no
`packiot_shadow` suffix needed — with a single flow there's nothing to disambiguate).
`edge-transformer` emits `refactored` only; `oeecloud-worker` runs the refactored lane
only (`CONSUME_LANES` small); no `SHADOW_EMIT_PRODUCTION`, no `shadow_go_port`, no
comparator. This is the cleanest possible topology — the thing ADR-0032 §1.1 calls "full
architectural latitude to simplify aggressively," achieved for free by not accreting the
legacy in the first place.

> **This supersedes ADR-0003's DB decision and should be recorded as its own short ADR**
> (proposed: "ADR-00XX — greenfield production is single-flow F3-native"). Flag for USER:
> ADR-0003 Phase 1/2 ("read-only shadow of existing prod DB") is **retired** by this;
> Phase 3 (cut writes from legacy EB) becomes "onboard first client onto new-prod
> directly," a different and simpler shape.

**The real build task hiding here (BLOCKER):** the F3 schema is *not* what edge-api's knex
migrations produce (those build the legacy `public`/F1 shape). The F3 schema is assembled
from `edge-node-red/db/*.sql` (e.g. `19-hasura-full-parity.sql`, `29-f3-analytics-port.sql`)
plus the oeecloud-worker rollup DDL (`internal/rollup/…`, schema-parameterized). Prod's
DB provisioning path must assemble **the F3 schema as `public`** — get this wrong and the
compute chain silently produces incorrect OEE. This is the single highest-care item in W1.

### 3.2 DECISION: re-cut `production` from `staging` (not merge, not cherry-pick)

**Recommendation: re-cut `production` from `staging`** (hard-reset the branch tip, deliberate
force-update), because:

- **Cherry-picking 568 commits is untenable** and error-prone.
- **A merge across a 4-week-old base produces spurious conflicts** on a frozen branch for
  no benefit.
- **`staging` is a strict superset of `production`.** Every prod-specific artifact
  (`compose.production.yml`, `terraform/production/`, `.github/workflows/deploy-production.yml`,
  prod DB init scripts) *already lives on `staging`* — verified: they're all present on
  `origin/staging`. So `production` holds **nothing** `staging` lacks → re-cut is pure gain,
  zero loss.

**Pre-flight before re-cutting (safety gate):** run `git diff staging production -- terraform/production
compose.production.yml .github/workflows/deploy-production.yml` and confirm it is empty or
only trivially behind. If any prod-only hotfix exists on `production` that never made it to
`staging`, capture it first. Since the prod EC2 has an **empty DB and no customer**, the
branch carries no operational risk to reset.

> This is a force-update of a protected branch → USER-gated. The roadmap recommends it;
> execution is a deliberate, announced step, done via a PR that makes `production` == `staging`
> plus the prod-delta commits layered on top.

### 3.3 DECISION: stay Docker-Compose-on-EC2 for the first client; k8s is later

ADR-0003 chose Compose; the org's north star (root `CLAUDE.md`) is k8s+ArgoCD. **Keep
Compose for client #1:**

- The Compose stack is **proven on staging** and the deploy chain (`deploy-production.yml`)
  already works end-to-end.
- k8s buys multi-node scheduling, self-healing, and multi-tenant scaling that **one client
  on one box does not need yet.**
- The migration seam is cheap later: services are already **containerized + git-submoduled**,
  so moving to k8s is a manifest-authoring exercise (`api-gitops` Kustomize), not a
  re-architecture. Revisit when N clients or HA SLAs justify the orchestration overhead.

Record k8s as an explicit **later** milestone; do not let it block client #1.

---

## 4. Sequenced workstreams

Legend — **[NOW]** = this-week-startable · **[LATER]** = has upstream deps ·
**BLOCKER** vs **nice-to-have** · effort in eng-days (rough).

### W1 — Stack promotion / compose parity  · BLOCKER · ~1.5–2.5 wk

| Step | When | Effort | Notes |
|------|------|--------|-------|
| 1.1 Verify `staging ⊇ production` diff; re-cut plan (§3.2) | **[NOW]** | 0.5d | pre-flight `git diff`; PR that resets `production`→`staging` |
| 1.2 Add the 8 migrated services to `compose.production.yml` (config only) | **[NOW]** | 2–3d | edge-transformer, mosquitto, ingest-shim, refdata-api, app-redis, operator-adapter, shadow-mirror(*maybe*), strip staging-only envs (plc-sim/triple-emit/comparator) |
| 1.3 Scaffold the missing `packiot/production/*` secrets (§2) | **[NOW]** | 1d | terraform `secrets.tf` additions; placeholder values, real ones at deploy |
| 1.4 **Assemble the F3 schema as prod `public`** (§3.1) | [LATER, after 1.2] | 3–5d | **highest-care** — DB provisioning path must build the F3 schema, not the legacy knex F1 shape; Hasura metadata (currently no-op) must track F3 objects |
| 1.5 Configure edge-transformer/worker for **single-flow F3-native** | [LATER] | 1–2d | `SHADOW_EMIT_REFACTORED=true` only, `CALC_CUTOVER_REFACTORED=true`, `CONSUME_LANES` small, no F1/F2 legs, no comparator |
| 1.6 First green dry-run deploy (empty DB, no ingest) | [LATER] | 1–2d | all services healthy against empty F3 DB — the boot-validation gate |

**W1 exit:** `production` == `staging` code, all target services boot healthy against a
fresh F3-schema DB, oeecloud-worker idle-but-ready. No client data yet.

### W2 — Prod ingest front-door  · BLOCKER · ~1 wk · [NOW] for terraform

Mirror ADR-0042 P1's staging pattern for prod. Two front-door flavors exist; **pick per
client transport** (they are different endpoints — install one):

- **Agent path (ADR-0042 P1):** client Node-RED tee → nginx TLS `:8447` →
  `sparkplug-agent-cpack :9104` → internal `mosquitto` → edge-transformer → F3. Runs real
  tags through the **real Calc**. Preferred when the client speaks SparkPlug/raw-tag.
- **Shim path (ADR-0032):** client tee → nginx/`ingest-shim :8444` (HTTPS, `X-Ingest-Key`)
  → `oee` exchange → oeecloud-worker → F3. Simpler republish front-door.

| Step | When | Effort | Notes |
|------|------|--------|-------|
| 2.1 SG rule: inbound TCP (8447 or 8444) **from client egress /32 only** | **[NOW]** | 0.5d | terraform `security_groups.tf`; NOT world-open; fill client CIDR from ops |
| 2.2 nginx vhost for the ingest port on the prod EC2 | [LATER] | 0.5d | reuse wildcard `*.prod.packiot.app` cert (already issued); `nginx -t && reload` |
| 2.3 DNS A record `<client>-ingest.prod.packiot.app` → EIP | **[NOW]** | 0.25d | terraform `dns.tf` `services` map |
| 2.4 Add `mosquitto` (+ agent) or `ingest-shim` to compose (from W1.2) | [LATER] | — | covered by W1 |
| 2.5 Per-client ingest key + tee-node deliverable | [LATER] | 0.5d | `docs/ingestion/*-tee-function.js` handed to client ops |

**W2 exit:** a client edge can uplink real SparkPlug over mTLS/HTTPS into prod's
edge-transformer → F3. Port stays closed until the client tee is scheduled live.

### W3 — Prod read plane  · BLOCKER · ~1.5–2 wk · ⚠ HIGHEST RISK

| Step | When | Effort | Notes |
|------|------|--------|-------|
| 3.1 Deploy `refdata-api` + `app-redis`; pgbouncer pool to the F3 DB | [LATER, after W1] | 1–2d | in greenfield prod `DB_NAME` = the single F3 DB directly — no dual-pool dance staging needs |
| 3.2 JWT verify (Firebase and/or Cognito) + `QUERY_API_KEYS` per tenant | [LATER] | 1–2d | issuer/client-id are public config; keys→customer(enterprise) id server-side |
| 3.3 Seed `users` rows for the client enterprise | [LATER] | 0.5d | refdata resolves tenant from `id_user_firebase`/`id_user_cognito` |
| 3.4 **Re-point front4 prod off legacy Hasura Cloud → new-prod refdata** | [LATER] | 3–5d | **⚠ THE big consumer cutover** — front4 config flip behind a flag; verify every dashboard renders off F3; the F3 read surface must be complete FIRST (analytics `h_piot_*` fns, config relations — see ADR-0032 §5) |
| 3.5 Re-point operator PWA prod → new-prod refdata | [LATER] | 1d | inherits refdata; response shapes must stay byte-stable |

**W3 exit:** front4 + operator render prod OEE off new-prod refdata → F3. **This is the
consumer cutover; treat 3.4 as its own gated mini-program** (flag-gated, shape-parity
verified against the legacy baseline before the customer-facing flip).

### W4 — PO / operator-write path  · BLOCKER · ~1 wk

How production orders + downtimes reach prod. **Greenfield simplification:** because prod
has no legacy F1 `public` substrate to preserve, edge-api can write operator actions
**directly to the single F3 DB** — this is ADR-0032's "Phase 2 edge-api-direct" end-state,
reached for free (no `shadow-mirror` bridge needed). See §5.

| Step | When | Effort | Notes |
|------|------|--------|-------|
| 4.1 Confirm edge-api writes operator actions to the single F3 DB | [LATER] | 1–2d | no `packiot.public`→`packiot_shadow` bridge in greenfield → **shadow-mirror likely unnecessary** |
| 4.2 Deploy `operator-adapter` if the client uses a bespoke operator UI | [LATER] | 1d | tees client PO actions → edge-api; else operator PWA's durable-write-queue is the path |
| 4.3 #32 staleness/durability gate live for the client enterprise | [LATER] | 0.5d | `PO_STALENESS_GATE_ENTERPRISES` includes the client id |

**W4 exit:** a PO start/stop + downtime driven from the operator UI lands correctly in the
single F3 DB.

### W5 — Parity / bake window  · GATE (not a build) · ~1–3 wk elapsed

Prove the client's data is correct in prod **before** anyone customer-facing sees it.
Greenfield has no `tsp12` baseline to diff against for this new client, so parity here is
**internal-consistency + spot-validation**, not a cross-flow comparator:

- **Internal consistency:** `equipment_values → equipment_runtime_shift/_1hour/_1day →
  uns_* views` fresh (<2s) and self-consistent; OEE = Q×A×P in-range (no `oee>1.0`,
  no double-count — the classic two-writer bug).
- **Spot-validation against the client's own numbers:** compare a shift's OEE / counts
  against what the client's existing system reports for the same window.
- **Bake elapsed ≥ 1 full shift cycle** (ideally a week spanning weekends/shift changes)
  with the read plane wired but **front4 still on the legacy source** — i.e. dark-launch:
  data flows into prod F3, nobody's dashboard points at it yet.

**W5 exit / the customer-flip gate:** internal consistency clean + client spot-check
agrees + bake ≥ 1 cycle → the client cutover (own program, own USER sign-off).

### W6 — Infra sizing  · BLOCKER for a real client · ~1 wk · [NOW] for terraform

**`t4g.medium` + a *local* TimescaleDB container will not survive a real client.** Staging
already proved this — the staging DB EC2 was undersized and *swapping*, needing a
`max_bg_workers` bump and a restart (TimescaleDB continuous-aggregate refresh is
memory-hungry). Adding edge-transformer + refdata + mosquitto + observability to the app
box compounds it.

| Step | When | Effort | Notes |
|------|------|--------|-------|
| 6.1 **Split the DB onto its own EC2** (use reserved `10.20.10.0/24` private subnet) | **[NOW]** (terraform plan) | 2–3d | copy staging's app+db split; the terraform already reserves the subnet + notes the phase-3 split |
| 6.2 Right-size the DB instance | [LATER] | — | **memory-first** family — `r7g.large`/`r7g.xlarge` (16–32 GB) or `m7g.large`; **not** `t4g.medium`. gp3 with provisioned IOPS; on-demand (WAL integrity — no spot) |
| 6.3 Bump the app EC2 | [LATER] | — | `t4g.large` (8 GB) minimum once the 8 extra services land; keep unlimited burst |
| 6.4 Add DB-from-app SG rule + backups/snapshots for the DB EC2 | [LATER] | 1d | mirror staging's `aws_security_group.db`; 30-day retention already set |
| 6.5 (later) managed option | [LATER] | — | consider RDS/Timescale Cloud once ops load justifies offloading DB admin |

**W6 exit:** DB on a dedicated, memory-sized instance; app EC2 sized for the full stack;
no swapping under real load.

---

## 5. The greenfield simplification worth calling out

Staging's architecture is dominated by *migration scaffolding* — triple-emit, F1/F2/F3
parallel run, comparators, `mirror-worker-go` fan-out, and `shadow-mirror` bridging
operator writes across the `packiot.public`→`packiot_shadow` DB boundary. **None of that
scaffolding is needed in greenfield prod**, because there is no legacy flow to run in
parallel with and no cross-DB boundary to bridge:

| Staging component | Why it exists on staging | Prod (greenfield) |
|---|---|---|
| triple-emit (`SHADOW_EMIT_*`) | validate F3 vs legacy F1/F2 | **gone** — emit `refactored` only |
| F1 `public` + F2 `shadow_go_port` | legacy + Go-decode shadow | **gone** — one DB, `public` = F3 |
| bake comparator / parity schemas | prove F3 == F1 before cutover | **gone** — nothing to compare against |
| `mirror-worker-go` | replay prod-CPACK into staging | **gone** — prod IS the source |
| `shadow-mirror` | carry operator writes F1→F3 (different DBs) | **likely gone** — edge-api writes F3 directly (§W4) |

This is the payoff of building prod fresh: prod lands directly at ADR-0032's *Phase 2
edge-api-direct* end-state (the "true single database") that staging can only reach after
a gated, multi-step collapse. **Confirm with USER** that shadow-mirror is dropped from the
prod compose (recommended) rather than carried defensively.

---

## 6. Risk register

| # | Risk | Severity | Mitigation |
|---|------|----------|-----------|
| R1 | **front4 read-plane re-point** blanks customer dashboards if F3 read surface is incomplete | **High** | W3.4 flag-gated; complete the F3 analytics/config surface (ADR-0032 §5: 26 `h_piot_*` fns + config relations) + shape-parity vs legacy baseline BEFORE flip; dark-launch first |
| R2 | **DB sizing** — `t4g.medium` + local TimescaleDB swaps and dies under real load | **High** | W6: split DB to a dedicated memory-family instance early; staging's swapping incident is the cautionary precedent |
| R3 | **Fresh-DB F3 schema assembled wrong** → silently incorrect OEE | **High** | W1.4 highest-care; validate schema against staging `packiot_shadow`; the W5 bake catches divergence before customers |
| R4 | Re-cutting `production` (force-update protected branch) | Medium | empty DB / no customer → no data loss; pre-flight `git diff` gate (§3.2); USER-gated |
| R5 | Ingest port exposure | Medium | SG `/32` from client egress only; port closed until tee scheduled; mTLS/`X-Ingest-Key` |
| R6 | Missing secrets → services crash-loop | Low | W1.3 scaffolds all `packiot/production/*` secrets before deploy |
| R7 | Single-EC2 = single point of failure | Medium (accepted for client #1) | on-demand (not spot) for WAL integrity; EBS snapshots + 30-day backup already set; HA is a k8s-era concern |
| R8 | Observability gaps (no tempo/alertmanager in prod compose) | Low | nice-to-have; port after the data path works |

---

## 7. Realistic timeline

Assuming one focused engineer + USER availability for the gated steps. Workstreams overlap
where deps allow (see §0 graph).

| Phase | Calendar | Content |
|-------|----------|---------|
| **Week 0** | this week | W0 decisions signed off; **compose-parity PR** (W1.1–1.3) + **ingest/DB-split terraform PR** (W2.1, W6.1) opened — all config/plan, no apply |
| **Weeks 1–2** | | W1.4–1.6 F3 schema + single-flow config + first green dry-run deploy; W6 DB-split applied |
| **Weeks 2–3** | | W2 ingest front-door live (internal validation, port closed); W3.1–3.3 refdata + auth up |
| **Weeks 3–4** | | W4 PO path; W3.4 front4 re-point built behind flag + shape-parity verified |
| **Weeks 4–6** | | client tee scheduled → real data flows dark; **W5 bake ≥ 1 shift cycle** |
| **Week 6+** | | customer-flip gate review → first client cutover (separate program) |

**Realistic end-to-end: ~5–7 weeks** to first-client-ready, with the customer-visible flip
gated on a clean bake. The long poles are the F3-schema assembly (R3), the front4 re-point
(R1), and DB right-sizing (R2) — none of which should be rushed.

---

## 8. Open decisions for USER (needed before/early execution)

1. **Confirm the fresh single-flow F3-native DB** (§3.1) and authorize recording it as an
   ADR that revises ADR-0003. *(Recommended: yes.)*
2. **Authorize the `production` re-cut from `staging`** (§3.2, force-update). *(Recommended: yes — empty DB, no data loss.)*
3. **Confirm dropping `shadow-mirror`** from the prod compose (§5) rather than carrying it. *(Recommended: drop.)*
4. **Ingest transport per client** — agent path (`:8447`, real Calc) vs shim path (`:8444`)? Depends on the client's edge (§W2).
5. **Client identity + egress CIDR** for the SG `/32` rule (from client ops).
6. **DB instance family/size budget** (§6.2) — `r7g.large` vs `r7g.xlarge` vs managed.
7. **Which is the first client**, and does it use the operator PWA or a bespoke operator UI (drives W4.2)?

---

## 9. What this roadmap explicitly does NOT do

- Does **not** promote, deploy, or `terraform apply` anything to production.
- Does **not** touch the legacy EB prod (`edge.api4.packiot.com`) or its DB.
- Does **not** read/write the legacy prod TimescaleDB (`tsp12`) — greenfield prod is
  independent of it.
- Does **not** perform the customer-facing cutover — that is a separate, gated program
  after the W5 bake.

---

## References

- [ADR-0003 — Production deployment of the parent stack](../0003-production-deployment-parent-stack.md) — this roadmap revises its DB decision (§3.1)
- [ADR-0032 — Collapse to single-flow F3](../0032-collapse-to-single-flow-f3.md) — the end-state prod is born into; §5 read-surface completeness informs R1
- [ADR-0042 P1 — CPACK tee front-door](../0042-cpack-tee-frontdoor.md) — the prod-ingest template (§W2)
- [ADR-0042 — Separated edge gateway](../0042-separated-edge-gateway.md) — client-edge split
- [ADR-0016 — Staging consolidation master plan](../0016-staging-consolidation-master-plan.md) — the schema end-state
- `compose.staging.yml` / `compose.production.yml` — the service diff (§1.1)
- `terraform/production/*` — SG (§W2.1), DNS/cert (§W2.3), sizing (§W6), secrets (§2)
- `.github/workflows/deploy-production.yml` — the deploy chain reused as-is
