# ADR-0060 — Local development environment: service slices + an anonymized CPACK dev seed

**Status:** Proposed · **Date:** 2026-10-06 · **Scope:** how a developer runs *one or a few*
services on a laptop with realistic inputs, without touching staging, AWS, or real client data.
**Supersedes:** `compose.development.yml` (stale since 2026-09-15: ~20 services, pre-medallion
topology with Hasura / `oee-cron`). **Builds on:** [ADR-0056](0056-single-app-db-with-schemas-not-control-plane-split.md)
(one app DB, schemas as the seam).

---

## 1. Context

### 1.1 The environment ladder

| Env | Purpose | Scope | Data | External deps |
|---|---|---|---|---|
| **development** (this ADR) | build + unit/slice test one service | 1–N services on a laptop (16–32 GB) | anonymized CPACK seed, ~7 days | **all faked locally** |
| **staging** | integration + e2e, the whole stack together | all 55 services (`compose.staging.yml`) | real staging DB `10.10.10.89` | real (Cognito, AWS) |
| **production** | customers | all | real | real — *not yet implemented* |

Development is **not** a mini-staging. Testing everything together is staging's job. Development
only has to answer: *"does my service behave correctly given realistic inputs?"*

### 1.2 What is broken today
- `compose.development.yml` describes an architecture that no longer exists. `make up` boots the
  wrong stack. The cause is structural, not neglect: **nothing exercises it**, so it drifted.
- Staging Postgres lives **outside** compose (`10.10.10.89`). There is no local DB that
  reproduces the current schema with data in it.
- 159 entries in `db/migrations/` with mixed naming (dated `.sql` files plus directories). Nobody
  has shown that replaying them builds today's schema from zero.
- Services are coupled to AWS by default: Cognito (`COGNITO_*`, 28 refs in staging compose),
  `AWS_REGION` in 10 services.

## 2. Decision

### D1 — Each service is a compose fragment and declares its inputs
A new `dev/` tree, independent of whether a service lives in-tree (`services/*`) or as a submodule
(`edge-api`, `front4`, …):

```
dev/
  compose.yml             # include: base + every fragment
  base.yml                # Tier 0 (always available)
  services/<svc>.yml      # one fragment per service: build, env, depends_on
  .env.dev                # checked in — fake values only, never a real secret
```

`docker compose up <svc>` already starts the `depends_on` closure, so **no profiles are needed**:
`make dev SVC="grafana read-api"` → `docker compose -f dev/compose.yml up grafana read-api`.
The repo layout (one repo per service or not) is a separate decision this ADR does not depend on.
A fragment can point its `build.context` at a submodule or an in-tree path equally.

Every fragment starts with a **contract header** (a comment block): inputs (tables read, queues
consumed, HTTP called), outputs (tables written, queues published), external deps. That header is
the isolation spec. Each input must be satisfied by Tier 0, by another fragment, or by a fake.

### D2 — Tiers

```
Tier 0  data plane   postgres+timescale (seeded), rabbitmq, mosquitto, redis, minio, mock-oidc
Tier 1  producers    replay (dev seed → MQTT/SparkPlug), simulator
Tier 2  processors   sparkplug-decoder, stream-engine, mirror-worker-go, analytics-sync, ingest-shim
Tier 3  APIs         edge-api, read-api, operator-gateway, barcode-service
Tier 4  UIs / obs    front4, csadmin, operator, customize, grafana, superset
```

Tier 0 always comes up **seeded**, so any Tier 3/4 service works with no pipeline running.
Starting Tier 2 is only needed when the pipeline itself is under test.

### D3 — External dependencies are faked locally

| Real | Dev stand-in | Notes |
|---|---|---|
| Cognito | mock OIDC issuer (e.g. `navikt/mock-oauth2-server`) + seeded dev users | read-api already reads `COGNITO_ISSUER` / `COGNITO_JWKS_URL` (`services/read-api/cmd/refdata-api/main.go:320`); audit the other services in P0 |
| S3 / historian Parquet | MinIO | |
| AWS SSM / Secrets Manager | `dev/.env.dev` | |
| Alertmanager / Slack | log sink | |
| Ollama | omitted by default | opt-in fragment (heavy) |

RabbitMQ is the only message bus. GCP PubSub belongs to the legacy path and has no place in dev.

### D4 — The CPACK dev seed: a versioned, anonymized DB image
A scheduled CI job builds `ghcr.io/packiot/devdb-seed:<YYYY-MM-DD>` (plus `:latest`): the Timescale
image (version pinned to staging) with the schema and ~7 days of CPACK data baked in.

**Pipeline:** `extract → anonymize → package → publish`

1. **Schema:** `pg_dump --schema-only` of `packiot_analytics` on staging. This is the baseline. The
   "replay all migrations from zero" check is a *separate* CI goal, not a blocker here.
2. **Extract:** `COPY (SELECT … WHERE <ts> >= snapshot_end - '7 days' AND <tenant = CPACK>) TO STDOUT`
   per table. `COPY (SELECT …)` reads compressed chunks transparently. **Never** call
   `decompress_chunk` on the shared DB (the 2026-09-30 incident rule). Run off-peak.
   Config/dimension tables (`core.*`, shifts, `packml_register`, equipments) are copied in full for
   the tenant. Tables outside the tenant are not extracted.
3. **Anonymize:** fail-closed (D5).
4. **Package:** loads into a fresh container and runs the invariant checks
   (`ops` invariants, #1543) against the result, so a seed that breaks invariants is never published.
5. **Publish** to GHCR. Developers pull it and never connect to staging.

**Volume budget:** compressed image ≤ ~1–2 GB. If CPACK's 7 days exceed it, cut to fewer lines
rather than fewer days, because the full-week shape (weekend, shift rotation) is the point.

### D5 — Anonymization is an allowlist, not a denylist
Every column of every extracted table must be classified in `dev/seed/classification.yml`:

| Class | Treatment | Examples |
|---|---|---|
| `keep` | copied as-is | numeric values, ids, timestamps, counters, status codes |
| `pseudonym` | deterministic mapping (same input → same output) | enterprise/site/area/equipment names → `Acme Packaging`, `Site A`, `Line 01`; products → `Product 0001`; clients → `Client 001`; PO codes |
| `rewrite` | structural rewrite that preserves meaning | `packml_topic` strings (contain enterprise/site names), JSONB descriptors |
| `null` | dropped | free text (downtime comments, notes), PLC IPs/hostnames |
| `replace` | synthetic | `auth.users` → seeded dev users only |

**Any unclassified column fails the extract.** That is the property that matters: when someone
adds a `notes` column next quarter, the seed job breaks loudly instead of leaking quietly.
Pseudonyms are deterministic (keyed HMAC, key in CI secrets) so that joins across tables still
work and the same machine stays `Line 03` across seed versions.

### D6 — Time-rebase on load: whole weeks
A snapshot is frozen in time, so every "last 24 h" dashboard goes empty a day after the pull. On
container init, the loader shifts every timestamp column by

```
Δ = floor((now() - snapshot_end) / 1 week) * 1 week
```

The load goes into staging tables and then `INSERT … SELECT ts + Δ`, so the rebase costs no
UPDATEs on hypertables.

**Why whole weeks.** It is the only Δ that keeps everything consistent without touching
configuration. `shift_hours.begin_time` is seconds from `week_begin`, hourly buckets stay aligned,
weekday and time-of-day patterns hold, and production days stay intact. The alternatives:

| Δ choice | "last 24 h" populated? | Shift calendar consistent? | Risk |
|---|---|---|---|
| exact `now - end` | yes | **no**: a 06:00 shift lands at 13:47 | silent wrong shift attribution |
| whole hours + shift `week_begin` by Δ mod week | yes | yes | rewrites config semantics; hard to reason about |
| **whole weeks (chosen)** | after replay (D7) | yes | data is 0–7 days old at boot |

Trade-off: in a Tier-0-only slice (for example Grafana alone), the newest data is between 0 and
7 days old. Dev dashboards default to "last 7 days". When "now" must be live, start Tier 1.

### D7 — Replay makes it live
`replay` (Tier 1) reads the seed's raw values for (now − 7 days) and publishes them as SparkPlug
over local MQTT at wall-clock pace, shifted forward one week. This is lap-based: week k+1 is
week k plus 7 days. With Tier 2 running, the real decoder and stream-engine compute fresh
silver/gold from it, so the pipeline is exercised end to end with realistic counters, stops, and
shift boundaries. It reuses `simulator/` where it can.

### D8 — Development cannot rot again
- CI boots `make dev SVC=<slice>` for the standard slices on every PR that touches `dev/`,
  `db/migrations/`, or a service, and runs a smoke check (health plus one real query per service).
- `compose.development.yml` and its `make up-*` targets are deleted when P2 lands.
- A long-lived `development` git branch is rejected. The dev environment lives on the same branch
  as the code it runs, so a schema change and its dev-seed impact land in one PR.

## 3. Phases

| Phase | Deliverable | Done when |
|---|---|---|
| **P0** | Contract inventory: one row per service (inputs, outputs, external deps, auth mechanism) derived from `compose.staging.yml` | table merged; every Cognito consumer known to accept a configurable issuer, or a gap is listed |
| **P1** | Seed pipeline (D4–D6) + Tier 0 + `grafana` slice | `make dev SVC=grafana` on a clean laptop shows CPACK-shaped (anonymized) dashboards |
| **P2** | mock OIDC + `read-api` + `front4` slice; delete `compose.development.yml` | log in as a dev user, Mission Control renders |
| **P3** | Tier 1 replay + Tier 2 processors | live "now" data flows decoder → stream-engine → gold, invariants green |
| **P4** | CI slice boots (D8); remaining fragments (csadmin, operator, customize, barcode, edge-api) | every service has a fragment and a CI smoke |

## 4. Consequences

**Good.** Onboarding a colleague takes `git clone --recurse-submodules && make dev SVC=…`.
No staging access, no AWS credentials, and no client data on laptops. Every seed build is a
weekly invariant check of a real week of production-shaped data.

**Costs.** A CI job and GHCR storage. The classification file must be maintained as the schema
grows (by design: that is the guard). Fragments duplicate some of `compose.staging.yml` until
staging is itself refactored onto the same fragments (possible future step, not in scope).

**Open questions**
1. Repo layout: extract `services/*` into separate repos (as submodules)? Independent of this
   ADR (D1). Decide on ownership/release-cadence grounds, not on "running one service alone".
2. Is a full-stack dev profile on a 32 GB machine worth maintaining, or is "all services" always
   staging? Proposal: allowed, best-effort, not CI-gated.
3. Which CPACK lines go into the seed if 7 days exceeds the volume budget?
