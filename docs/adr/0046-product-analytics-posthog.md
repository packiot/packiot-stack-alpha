# ADR-0046 — Product analytics for front4: self-hosted PostHog (heatmaps · session replay · funnels)

**Status:** Proposed (DESIGN ONLY — build/provision gated) · **Date:** 2026-07-27 · **Scope:** front4 + packiot-stack-alpha (staging first) · **Decision owner:** chief architect (pending USER sign-off) · **Pillar:** P10 Dashboards/Viz (adjacent) + P15 Observability/Ops (adjacent) — introduces a **new capability: product analytics** not currently owned by any pillar.

**Relates to:**
- [ADR-0038](0038-north-star-factory-platform.md) §5.9 — *single cloud (AWS)*: "one IAM, one billing, no cross-cloud seams". PostHog must land on AWS with no third-party data egress.
- [ADR-0034](0034-adopt-cognito-amplify-auth.md) — identity is migrating Firebase → Cognito; PostHog's `distinct_id` must key on the **provider-agnostic uid**, not a Firebase-specific field.
- [ADR-0036 §2.4](0036-data-architecture-medallion.md) / [ADR-0041](0041-gcp-exit-lakehouse.md) — the **business-BI** tier (S3 + Glue + Athena, QuickSight/Redshift-later). PostHog is a **distinct third analytics pillar** (see §1.1), not part of the lakehouse.
- [ADR-0029](0029-front4-dashboard-composition-and-metric-layer.md) — the front4 composition engine + widget registry. Product-analytics heatmaps *feed* the "which tiles earn their place" question this ADR-0029 registry raises.
- [ADR-0042 P1](0042-cpack-tee-frontdoor.md) — the nginx-vhost + wildcard-cert + SG front-door pattern PostHog's ingress reuses verbatim.

> **This is a DESIGN-ONLY ADR.** It decides the shape and sequences the work; it provisions nothing, adds no snippet to front4, and merges no compose/terraform. Every "build" step below is explicitly USER-gated and phased **after the current CPACK-tee / F2–F3 parity work settles**.

---

## 1. Context & problem

front4 is a mature operational UI (Overview/OEE/downtimes/production-orders dashboards, ADR-0029 composition engine), but **we are blind to how it is actually used.** We know what the *machines* do (Grafana/Prometheus, ops pillar) and we are building what the *business* looks like (Athena/QuickSight lakehouse, BI pillar) — but we have **zero product-analytics**: no heatmaps of where operators click, no session replay of a confused user's journey, no funnel of task completion, no retention curve. The only front-end telemetry today is New Relic Browser (RUM — page load timing, JS errors), which measures *performance*, not *behavior*.

The USER's standing constraints frame the whole decision:
1. **"Everything private"** — a hard, load-bearing invariant (the security thread is parked precisely on this). Analytics data about our users and our clients' operators must **never leave our AWS account**.
2. **Single cloud (AWS)** — ADR-0038 §5.9. No new third-party SaaS dependency, no cross-cloud seam.
3. **LGPD (Brazil-based) + GDPR** — session replay and click analytics can capture PII; consent + masking are not optional.
4. **Real scale is small** — a handful of internal CS/operator users plus per-tenant client-dashboard viewers. This is **not** a millions-of-events consumer product. Sizing must be honest about that.

### 1.1 The three-pillar analytics model (where PostHog fits)

| Pillar | Question it answers | Tool | Grain | Status |
|---|---|---|---|---|
| **Ops / observability** | Is the *platform* healthy? (RED, latency, ingest silence, engine stalls) | **Grafana + Prometheus/Loki/Tempo** | services & pipelines | STRONG (ADR-0038 P15) |
| **Business BI** | What do the *factories* look like? (OEE trends, loss reports, cross-tenant KPIs) | **Athena/S3 lakehouse → QuickSight** | production data | MATURING (ADR-0036/0041) |
| **Product analytics** *(this ADR)* | How do *users* navigate the *app*? (heatmaps, replay, funnels, retention) | **PostHog** | front4 clickstream | MISSING → this ADR |

These are genuinely orthogonal: Grafana never sees a click, the lakehouse never sees a scroll, and PostHog never sees an OEE number. PostHog is the missing third leg — the *product* lens.

---

## 2. Decision — and the honest footprint

**Decision (recommended): self-host PostHog on a dedicated AWS EC2 (Docker-Compose "hobby" tier), as a gated, reversible pilot — with an explicit kill-criterion and a documented fallback to Matomo.** It is the only option that delivers all three wanted capabilities (heatmaps **and** session replay **and** funnels) in a single OSS tool **without any data leaving our AWS account**. The privacy invariant (§1 constraint 1) is what makes the decision; everything else is right-sizing.

But this recommendation is only honest if it names the cost squarely. **Self-hosted PostHog is not lightweight, and we are deploying it at a scale PostHog itself steers away from self-hosting.** Three hard facts:

### 2.1 PostHog self-host is a heavy, semi-supported box

PostHog's self-host bundle is not one process — it is a **distributed data system**: `web` + `worker` (plugin-server) + **ClickHouse** (columnar event store, the heavy one) + **Kafka** (ingest buffer) + **Postgres** (metadata) + **Redis** (cache/queue) + **MinIO** (object storage) + Caddy (proxy). None of ClickHouse or Kafka exist in our stack today (our bus is RabbitMQ, our store is TimescaleDB) — PostHog brings its **own** parallel data plane.

- **Official minimum: 4 vCPU / 16 GB / 30 GB+.** Real-world reports put a comfortable floor nearer **32 GB** because ClickHouse + Kafka + Postgres + Redis co-resident will OOM-kill under 16 GB when events flow. Our current staging *app* box is a **t4g.medium (2 vCPU / 4 GB)** — already tight enough that Authentik alone forced a t4g.small→medium upgrade. PostHog cannot co-locate; it needs its **own** instance **~4× the RAM**.
- **Kubernetes/Helm self-hosting was SUNSET in May 2023.** The only self-host path PostHog still develops is the **Docker-Compose "hobby" deployment** — MIT-licensed, **explicitly "without support"**, and documented to scale to **~100k events/month**, after which PostHog **recommends migrating to PostHog Cloud**. This directly **contradicts the stack's K8s/ArgoCD north-star for prod** (root CLAUDE.md): there is **no supported PostHog Helm chart to graduate to.** Prod PostHog would be the *same* docker-compose-on-EC2 as staging, not an ArgoCD app. That is a real architectural exception we must accept eyes-open.
- **ARM64 mismatch.** Our entire stack is **Graviton / ARM64** (al2023-arm64, t4g). PostHog's hobby compose ships an **x86-only Kafka that segfaults randomly on ARM** and must be restarted when it does. So the PostHog host either (a) runs **x86** (a t3/m6i box — breaking the ARM uniformity for this one service), or (b) fights arm64 Kafka images as a standing ops tax. **Recommendation: run the PostHog EC2 as x86** and quarantine the exception to one instance.

### 2.2 The options table (honest comparison)

| Option | Private? (data stays in our AWS) | Heatmaps | Session replay | Funnels/retention | Footprint / effort | Verdict |
|---|---|---|---|---|---|---|
| **(a) Self-hosted PostHog** *(recommended)* | ✅ **Yes** — never leaves AWS | ✅ (autocapture) | ✅ (built-in) | ✅ | **Heavy** — dedicated 16 GB+ x86 EC2, CH+Kafka, unsupported hobby tier, ~3× staging bill | **CHOSEN** — only fully-private all-in-one; accept the footprint, gate & phase it |
| (b) PostHog Cloud (EU/US) | ❌ **No** — events leave to PostHog's infra | ✅ | ✅ | ✅ | Zero ops, generous free tier (1M ev/mo) | **Rejected on privacy** — the pragmatic pick *if* "everything private" were ever relaxed; noted as the honest fallback |
| (c) Microsoft Clarity | ❌ **No** — data → Microsoft | ✅ | ✅ | ⚠️ weak funnels | **Zero** effort/cost, free | **Rejected on privacy** — best-effort/lowest-cost, but data leaves |
| (d) Matomo self-hosted | ✅ **Yes** | 💰 **paid plugin** | ⚠️ newer/limited | ✅ | **Lighter** — PHP + MariaDB, no ClickHouse/Kafka | **Fallback** — much lighter; but heatmaps/replay are paid/weaker. The escape hatch if PostHog's footprint proves not worth it |
| (e) CloudWatch RUM | ✅ **Yes** — AWS-native | ❌ (perf RUM, not click/scroll) | ❌ | ❌ | Native, cheap | **Rejected on capability** — measures performance, not behavior; overlaps New Relic, not PostHog |

### 2.3 The honest recommendation, stated plainly

**Given the hard privacy invariant, (b) and (c) are out on constraint, not merit** — they are the *convenient* answers, and if the USER ever relaxes "everything private," **PostHog Cloud EU is by far the most pragmatic choice for our scale** (name it so the decision is on record). Within the private set, (a) PostHog uniquely gives heatmaps + replay + funnels in one tool with data-never-leaves-AWS; (d) Matomo is lighter but charges for heatmaps and has weaker replay.

**So: self-host PostHog — but treat it as a gated pilot, not a foregone commitment.** For a handful of internal users, a dedicated 16 GB ClickHouse+Kafka box is honestly a *sledgehammer*; the justification is the **capability** (private session replay + heatmaps), not the volume. Therefore:

- **Kill-criterion (write it into P0):** if, after the staging pilot, the ops burden (arm/x86 split, unsupported upgrades, OOM babysitting, ~3× cost) outweighs the product-insight value for the actual user count → **fall back to Matomo self-hosted** (option d) or revisit Cloud if the privacy stance moves. Do not let sunk-cost carry a heavy box for 10 users.
- **Autocapture caveat:** autocapture is *chatty*. Even a handful of users navigating polling dashboards can exceed the 100k-events/month "hobby ceiling" — that ceiling is a *when-to-move-to-Cloud* heuristic, not a hard cap for a private box, but it means we must tune capture (disable autocapture on high-frequency polling widgets; sample) to keep ClickHouse and the bill sane.

---

## 3. Deployment architecture on AWS

PostHog lands as **one dedicated EC2 running the hobby docker-compose**, fronted by the *existing* host-nginx + Authentik + wildcard-cert ingress — reusing the ADR-0042 P1 pattern verbatim. It does **not** join `compose.staging.yml` (that box is a 2 vCPU / 4 GB t4g.medium already at its ceiling); it is its own instance following the established two-EC2 pattern (`terraform/staging/ec2.tf`).

```
Browser (front4 SPA)
  │  posthog-js  →  https://posthog.staging.packiot.app/{e,i,decide,s}/   (ingest, NO Authentik gate)
  │                 https://posthog.staging.packiot.app/  (UI, Authentik-gated)
  ▼
host nginx (app EC2, TLS via LE wildcard, DNS-01/Route53)
  │  vhost posthog.staging.packiot.app  →  proxy_pass  posthog-web
  ▼
────────────────────  dedicated PostHog EC2 (x86, private subnet + EIP-or-ALB)  ────────────────────
  posthog-web + posthog-worker
  ├─ ClickHouse  (event store)      → dedicated gp3 data volume, grows with events
  ├─ Kafka       (ingest buffer)    → x86 image (arm segfaults)
  ├─ Postgres    (metadata)         → PostHog's own; OR a `posthog` DB on the shared TimescaleDB EC2 (Authentik precedent)
  ├─ Redis       (cache/queue)      → dedicated posthog-redis (do NOT share app-redis: LRU, no persistence)
  └─ object storage (session-replay blobs)  →  S3  (swap MinIO → real S3 via OBJECT_STORAGE_* env)
                                                   bucket: packiot-staging-posthog-recordings-${account_id}
```

### 3.1 Ingress (reuse the existing seam — near-zero new code)

The stack already generates one nginx vhost + one Route53 A-record per entry in the terraform `services` map (`terraform/staging/variables.tf`), each behind an Authentik `auth_request` forward-auth gate (`user_data/nginx_setup.sh`). Adding PostHog is mechanically:

```hcl
# terraform/staging/variables.tf — services map
posthog = 8000   # → posthog.staging.packiot.app, A-record + nginx vhost auto-generated
```

**One required carve-out:** the PostHog **ingest** endpoints (`/e/`, `/i/`, `/decide/`, `/s/`, `/array/`) are hit by unauthenticated browsers/SDKs and **must skip the Authentik gate** — exactly mirroring the existing `%{ if svc == "api" }` carve-out in `nginx_setup.sh` that already exempts `location ~ ^/api/`. The **UI** (`/`) stays Authentik-gated (only staff log into the PostHog console). TLS terminates at host-nginx with the existing Let's Encrypt **wildcard** cert (`*.staging.packiot.app`, DNS-01 via Route53) — no new cert.

### 3.2 Sizing (ClickHouse is the heavy one)

| Component | Sizing note |
|---|---|
| **PostHog EC2** | **x86** t3.xlarge / m6i.xlarge (**4 vCPU / 16 GB**) minimum; watch for OOM and be ready to go 32 GB. NOT the ARM t4g line (Kafka segfault). Dedicated instance — never colocate on the app box. |
| **ClickHouse data** | Dedicated **gp3 EBS**, start ~50–100 GB, **plan to grow** (event volume drives it; autocapture is chatty). Tag `Backup=daily` so AWS Backup snapshots it (`snapshots.tf` pattern). |
| **Session-replay blobs → S3** | Replay is the **fastest-growing + highest-PII** data. Point PostHog object storage at S3 (not MinIO on local disk). **Short lifecycle expiry (30–90 days).** |
| **Postgres (metadata)** | Small. Either PostHog's own container, or a `posthog` database on the shared TimescaleDB EC2 (the Authentik precedent — `authentik` DB already lives there). |
| **Redis** | Dedicated `posthog-redis` (`redis:7-alpine`, resource-capped, matching the app-redis pattern). **Do NOT reuse app-redis** — it's an LRU cache with persistence off; sharing risks evicting PostHog keys. |

### 3.3 Terraform surface (all gated, spec-only)

Copy `backups.tf`'s S3 template exactly for a **`packiot-staging-posthog-recordings-${account_id}`** bucket: `aws_s3_bucket` + `public_access_block` (all four true) + `server_side_encryption_configuration` (SSE-KMS) + `versioning` + `lifecycle_configuration` (expire replay blobs 30–90d) + a scoped `aws_iam_policy` (Put/Get/Delete on `arn/*`, List on the bucket) attached to the PostHog instance role. New: `aws_instance.posthog` (x86 AMI, t3.xlarge, dedicated gp3 data volume, `Backup=daily` tag), an SG (inbound 8000 from the app-EC2 nginx only; egress to Postgres/S3), and `posthog = 8000` in the `services` map (gets the DNS A-record + vhost for free).

### 3.4 Prod path (honest)

**There is no ArgoCD/K8s path** — PostHog sunset Helm (§2.1). Prod PostHog = the **same docker-compose-on-a-dedicated-EC2** as staging, sized up, in `compose.production.yml`'s deployment model. This is a deliberate exception to the K8s north-star, justified because PostHog is an isolated satellite (its own data plane, its own box) that never touches the OEE spine. If that exception feels wrong at prod-decision time, that is the moment to reconsider Matomo (d) or Cloud (b).

---

## 4. front4 integration

front4 is a **Vite + React 17 SPA** (dual Firebase/Cognito auth). Integration mirrors the *existing* conventions — the New Relic inline-snippet precedent, the `VITE_*` env-gate pattern (the `COGNITO_ENABLED` gate is the template), and the `firebase.js`/`cognito.js` init-module shape.

### 4.1 The snippet — a gated init module (`src/posthog.js`)

Mirror `cognito.js`: a module that reads `import.meta.env.VITE_POSTHOG_*` and is **OFF by default**, so a build without the vars is a no-op.

```js
// src/posthog.js  (sketch — NOT to be added until P1)
const ENABLED = String(import.meta.env.VITE_POSTHOG_ENABLED).toLowerCase() === "true";
const KEY  = import.meta.env.VITE_POSTHOG_KEY;
const HOST = import.meta.env.VITE_POSTHOG_HOST;          // https://posthog.staging.packiot.app
export const POSTHOG_ENABLED = ENABLED && Boolean(KEY); // exact COGNITO_ENABLED shape
```

Init is deferred behind consent (§4.2) and behind the async tenant hydration (§4.3). Provider nesting lives in `src/index.jsx` (`BrowserRouter → AuthProvider → ApolloProvider → VariablesProvider → App`); wrap or init inside `VariablesProvider` so identity context is reachable.

### 4.2 Consent-gated (LGPD/GDPR) — this is not optional

front4 has **no existing consent mechanism** — this is built from scratch. PostHog must initialise with capturing **opted out by default** and only start on explicit opt-in:

```js
posthog.init(KEY, {
  api_host: HOST,
  opt_out_capturing_by_default: true,   // no capture until consent
  persistence: "memory",                // no cookies pre-consent
  // ...masking config, see §4.4
});
// only after the user accepts the consent banner:
posthog.opt_in_capturing();
```

Legal basis split: **internal CS/operator users** may run on documented legitimate-interest (internal tool); **external client-dashboard viewers** need explicit consent. A minimal cookie/consent banner is a P2 deliverable.

### 4.3 Identity — reuse the refdata/QuickSight identity seam

Segment analytics **per tenant** by identifying on the **provider-agnostic uid + `id_enterprise`** — the same identity front4 already resolves for refdata. The clean source is `src/services/authToken.js` → `getAuthToken().uid` (Firebase `uid` *or* Cognito `sub` — future-proof against ADR-0034). Tenant comes from `VariablesContext` / `localStorage.id_enterprise`.

```js
// fire from VariablesContext onCompleted / a useEffect watching `enterprise` — NOT at bootstrap
posthog.identify(uid, { enterprise_name, username });
posthog.group("enterprise", String(idEnterprise));   // per-tenant segmentation
```

**Timing caveat (load-bearing):** `id_enterprise` is populated **asynchronously** (the `GET_VARIABLES_CONTEXT` GraphQL query in `VariablesContext.jsx`, with a mount `setTimeout`). `identify`/`group` **must** wait for that query's `onCompleted` (or watch the `enterprise` state), never fire at page load — else events land un-tenanted. On logout, `AuthContext.logout()` already `localStorage.clear()`s — add **`posthog.reset()`** there.

**SPA pageviews:** posthog-js autocapture does **not** see react-router v6 client-side navigations. Add a `useLocation()` effect in `App.jsx` (which already renders `useRoutes`) to `posthog.capture('$pageview')` on route change — otherwise heatmaps/funnels see only the first hard load.

### 4.4 PII masking — default-safe session replay

Session replay can capture PII (operator names, order data, anything on screen). Masking must be **default-on**, not opt-in:

```js
session_recording: {
  maskAllInputs: true,                 // every <input> masked (default-safe)
  maskTextSelector: "[data-ph-mask]",  // opt-in masking hook for sensitive text
},
autocapture: { /* enabled for heatmaps; consider disabling on polling widgets */ },
```

Then **mask *text*, not just inputs, on sensitive routes** — `login`, `settings/users-and-permissions`, anything showing PII — via `maskAllText`/route-scoped config or `data-ph-no-capture` on those subtrees. Passwords are masked by default (`input[type=password]`) but assert it. Rule: **replay is default-blind and pages opt into showing text**, never the reverse.

---

## 5. What it answers (front4-specific)

| Capability | Concrete front4 question |
|---|---|
| **Heatmaps** (click + scroll, per page) | *Which OEE/Overview tiles do operators actually click?* Directly informs the **ADR-0029 widget registry** — which composed tiles earn their place vs. which are dead weight. Scroll-depth: do users ever reach the below-the-fold widgets? |
| **Session replay** | Watch a confused operator's real journey to diagnose a support ticket ("why couldn't they justify that downtime?"). Reproduce a bug from the user's actual clicks. |
| **Funnels** | *Downtime-justification* completion: event appears → operator opens → assigns reason → splits → saves. Where do they drop? *Onboarding* (settings: targets/users/downtime-reasons) completion. |
| **Retention** | Do client-dashboard users **return** (daily/weekly)? A tenant whose users stop coming back is a churn signal invisible to OEE metrics. |
| **Per-tenant segmentation** | Via `group('enterprise', …)`: compare how Incoplast vs CPACK operators navigate — is a customization actually used, or ignored? |

---

## 6. Phased rollout

**Gate: begin only after the current CPACK-tee / F2–F3 parity work settles** (this is not on the critical path; it must not compete for attention with the OEE cutover).

| Phase | Deliverable | Gated by |
|---|---|---|
| **P0** | Deploy hobby compose on a **dedicated x86 EC2**; `posthog.staging.packiot.app` behind Authentik (ingest carve-out); S3 for replay blobs; `posthog-redis`; ClickHouse on dedicated gp3. **Prove it stands up + survives a shift.** No front4 wiring. Write the **kill-criterion** review here. | USER (new EC2 + terraform apply) |
| **P1** | front4 snippet as `src/posthog.js`, **consent-gated + OFF by default** (`VITE_POSTHOG_ENABLED=false`), autocapture for heatmaps, `useLocation` pageview listener. Staging only. | P0 healthy |
| **P2** | Session-replay with **PII masking defaults**; `identify(uid)` + `group(enterprise)` on async tenant hydration; consent banner; build the heatmap/funnel/retention dashboards. | P1 |
| **P3** | Prod — **dedicated prod EC2 docker-compose** (NOT ArgoCD; Helm is sunset), sized up; OR trigger the **kill-criterion fallback to Matomo/Cloud** if the pilot's burden outweighed the value. | USER + P2 signed off |

### 6.1 Cost estimate (honest, ~3× the current staging bill)

Current staging is **~$41/mo** (2× t4g.medium + NAT + EBS + misc). PostHog adds, roughly:

| Item | Est. /mo |
|---|---|
| PostHog EC2 (x86 t3.xlarge, 4 vCPU/16 GB, on-demand) | **~$120** (much less if stopped-when-idle on staging, or spot) |
| Dedicated ClickHouse gp3 (100 GB) | ~$8 |
| S3 replay blobs (handful of users, 30–90d lifecycle) | ~$1–5 |
| **PostHog subtotal** | **~$130–140/mo** |

→ Roughly **3–4× the staging bill** for a handful of users. This is the number that makes the kill-criterion (§2.3) real. On staging, aggressively consider **stop-when-idle** (the box need not run 24/7 during a pilot) to cut the EC2 line to a fraction.

---

## 7. Data privacy & retention (LGPD stance)

1. **Self-hosted = data never leaves our AWS account.** This is the whole reason for choosing (a) over Cloud/Clarity — it satisfies "everything private" and LGPD data-minimisation by construction. Region: default us-east-1 (co-located with the stack); if LGPD data-residency is asserted strictly, the PostHog EC2 + S3 bucket can pin to **sa-east-1 (São Paulo)** independently of the OEE stack — document the choice either way.
2. **Session-replay masking defaults (§4.4):** `maskAllInputs: true` always; text masked on sensitive routes; passwords never recorded. Replay is default-blind; pages opt in to showing text.
3. **Consent (§4.2):** opt-out-by-default init; explicit opt-in for external client users; documented legitimate-interest for internal tooling; a consent banner (P2).
4. **Retention policy:** ClickHouse event TTL (e.g. 12 months); **session-replay S3 lifecycle expiry 30–90 days** (replay is the biggest storage + highest PII risk — keep it short). Both are enforced *in our infra*, not by a vendor.
5. **Access:** the PostHog console is Authentik-gated (staff only, §3.1); ingest endpoints are the only unauthenticated surface and accept only capture writes.

---

## 8. Consequences

**Positive:** the missing third analytics pillar (product behavior), fully private, all-in-one (heatmaps + replay + funnels), reusing the existing ingress + identity seams with near-zero new front4 plumbing, phased and reversible.

**Negative / accepted:** a heavy, **unsupported** hobby-tier data system (ClickHouse + Kafka) on a **dedicated ~16 GB x86** box that breaks ARM uniformity; **no supported prod K8s path** (Helm sunset — a deliberate exception to the north-star); **~3–4× the staging bill** for small scale; autocapture volume needs tuning; consent + masking are new front4 work. All of these are why P0 ships **with a written kill-criterion and a Matomo fallback**, not an open-ended commitment.

**Rejected:** PostHog Cloud & Microsoft Clarity (data egress — fail the privacy invariant; named as the honest picks *if* privacy is ever relaxed); CloudWatch RUM (performance RUM, not behavioral — wrong tool). Matomo self-hosted is **not rejected** — it is the documented fallback (lighter, but heatmaps paid / replay weaker).

---

## Appendix — key facts referenced

- **Stack ingress:** host-nginx (not containerized) on the app EC2, TLS via Let's Encrypt **wildcard** cert (`*.staging.packiot.app`, DNS-01/Route53), one vhost + Route53 A-record per `services`-map entry (`terraform/staging/variables.tf`, `user_data/nginx_setup.sh`), all behind Authentik `auth_request` forward-auth (carve-out precedent: `location ~ ^/api/`).
- **Staging infra:** 2× **t4g.medium (2 vCPU/4 GB, Graviton/ARM64)** app+db, 64 GB gp3 each, ~$41/mo total. **No ClickHouse, no Kafka, no Zookeeper** in-stack (bus = RabbitMQ). Redis exists (`app-redis` LRU-no-persistence + `authentik-redis`) — neither reusable for PostHog. Shared external TimescaleDB EC2 (Authentik has its own `authentik` DB there — the reuse precedent).
- **S3 convention:** `packiot-staging-<purpose>-${account_id}`, public-access-blocked, SSE, versioned, lifecycle'd, scoped IAM on the instance role (`backups.tf`).
- **front4:** Vite + React 17 SPA; dual Firebase/Cognito auth; provider-agnostic uid via `src/services/authToken.js`; tenant via `VariablesContext`/`localStorage.id_enterprise` (async); `VITE_*` env-gate convention (template: `src/cognito.js` `COGNITO_ENABLED`); New Relic inline-snippet precedent; no existing consent mechanism; route-change pageviews need a `useLocation` listener (react-router v6).
- **PostHog facts (2026):** hobby docker-compose is the only supported self-host (MIT, "without support", ~100k ev/mo → Cloud); **Helm/K8s sunset May 2023**; min 4 vCPU/16 GB (realistically 32 GB); components web+worker+ClickHouse+Kafka+Postgres+Redis+MinIO; **x86 Kafka segfaults on ARM**.
</content>
</invoke>
