# ADR 0004 — Edge-nodered config centralization per client

**Status:** Proposed
**Date:** 2026-06-29
**Author:** Emmanuel Podestá (with Claude Code as drafting partner)
**Reviewers:** Packiot platform team

---

## Context

### The current config sprawl

Edge-nodered's per-client variation lives in at least **four separate places** with no canonical source of truth:

1. **GitHub Secrets per enterprise** — Each onboarded client has a parallel set of secrets:
   - `ENTERPRISE_<NAME>_SERVICE_ACCOUNT`
   - `ENTERPRISE_<NAME>_PUBSUB_TOPIC`
   - `ENTERPRISE_<NAME>_ID`
   - `ENTERPRISE_<NAME>_API_KEY`
   - (see `enterprise-neopac-wil-deploy.yml` for the live shape)

2. **`compose.yml` env block** — Per-deploy environment variables baked in at compose time:
   - `ID_ENTERPRISE` (the integer ID)
   - `API_KEY` (auth to edge-api)
   - `PUBSUB_TOPIC`, `SERVICE_ACCOUNT`, `CREDENTIAL_PATH`, `ID_PUBSUB_NODE`
   - (these come from the GitHub Secrets above via the deploy workflow)

3. **`transform_flows.py` build-time rewrites** — Hardcoded values in `flows.json` and `flows/*.json` get rewritten at image-build time:
   - Firebase API key literal → `$(FIREBASE_API_KEY)`
   - Hardcoded Hasura URLs → `env.get('HASURA_URL')`
   - Calc_Counters bug fixes (timestamp override removal, debug var stripping)
   - The HASURA_ADMIN_SECRET bypass injection (when set)

4. **Postgres `packml_register` table** — The actual SparkPlug-topic-to-equipment mapping lives in the production database; onboarding a new client means manually inserting rows (CS engineer task, no declarative source).

Plus per-client variation in:
- **Equipment topology** — which machines are on which lines, line layout, equipment types (1=machine, 2=sector, 3=line)
- **Operator UI** — labels, languages, feature flags (today hardcoded in operator SPA or per-tab flow files)
- **Topic prefix** — `C-PACK` (CPACK enterprise prod prefix) vs the canonical `CPACK` after remap; new clients would need their own prefix

### What goes wrong with the sprawl

- **Onboarding a new client = 4-5 separate places to edit**, each with its own access pattern (GitHub UI, Secrets Manager UI, compose.yml git edit, transform_flows.py git edit, DB manual INSERT)
- **No declarative diff between clients** — comparing "what's different about CPACK vs SimCorp?" requires grepping across multiple repos + the DB
- **Easy to forget a step** — a missed `packml_register` row means equipment events never make it to OEE math; a wrong `ID_ENTERPRISE` means data misrouting (we've already seen this kind of bug — the simulator hardcoded `gateway:"simulator"` for all 117 machines regardless of enterprise; took weeks to find)
- **Equipment list drift** — when a client adds a new machine on the factory floor, the canonical "what equipment exists" lives only in `packml_register`; no version control, no PR review, no rollback

---

## Decision

Adopt a **single per-client declarative config file** as the canonical source of truth for everything that varies per client (except real secrets). The file lives in `clients/<client-id>/client.yaml` under the `edge-node-red` repo. The deploy workflow selects which client config to bake into the runtime via a single `CLIENT_ID` env var. Postgres `packml_register` is **seeded from this file** at deploy time (idempotent upsert), making the YAML the source of truth for equipment topology.

### File layout (proposed)

```
edge-node-red/
├── clients/
│   ├── cpack/
│   │   └── client.yaml
│   ├── neopac-wil/
│   │   └── client.yaml
│   ├── simcorp/
│   │   └── client.yaml
│   └── _template/
│       └── client.yaml          # canonical schema + comments for onboarding
├── flows.json
├── flows/
├── transform_flows.py
└── ...
```

### Schema (proposed `client.yaml`)

```yaml
# clients/cpack/client.yaml
#
# Single source of truth for everything that varies per Packiot client.
# Secrets (API keys, passwords, service-account JSON) are NOT here — they
# stay in AWS Secrets Manager / GitHub Secrets per the security model.

enterprise:
  id: 3                                # ID_ENTERPRISE env var
  name: CPACK
  display_name: "CPACK Embalagens"     # what operator UI shows
  topic_prefix: CPACK                  # canonical edge-side prefix
  cloud_topic_prefix: C-PACK           # what prod ingests; remapped by RemapTopic()

sparkplug:
  gateway_id: cpack                    # used by gateway-derivation logic
                                       # (replaces the simulator's hardcoded "simulator")

equipment:
  # Declarative source of truth for packml_register seeding.
  # Each entry becomes (idempotent) INSERT/UPDATE on packml_register +
  # equipments tables at deploy time.
  - id: 47
    name: L5
    type: line                         # 1=machine, 2=sector, 3=line
    topic: CPACK/SC/LINHAS/L5
    area_id: 10
    site_id: 6
    children:                          # nested for line→machine topology
      - id: 68
        name: L5-DXL
        type: machine
        topic: CPACK/SC/LINHAS/L5/DXL
        id_unit: 68
      - id: 69
        name: L5-TEXA
        type: machine
        topic: CPACK/SC/LINHAS/L5/TEXA
        id_unit: 69

ui:
  language: pt-BR
  features:
    operator_actions: true             # justify, edit, split events
    po_management: true                # start/stop/change PO
    sample_capture: false
  labels:
    welcome: "Bem-vindo ao CPACK"
    no_active_po: "Nenhuma OP ativa"

cloud:
  # Service endpoints — defaults populated; per-client overrides go here
  # if a customer is on a different cloud region or has a private API.
  edge_api_base_url: https://api4.packiot.com        # null → default from compose env
  hasura_url: null
  pubsub_project_id: packiot-prod
```

### Consumption pattern

Three consumers, in clear precedence order:

| Consumer | What it reads | When |
|---|---|---|
| **`transform_flows.py`** (build time) | `enterprise.cloud_topic_prefix`, `sparkplug.gateway_id` for URL-rewrite + gateway-derivation logic that today is per-client-hardcoded | Docker image build |
| **`db/seed-equipment.sql.tpl`** (deploy time) | `equipment` tree | New `db-migrate-client` compose service, runs idempotent UPSERT into `equipments` + `packml_register` |
| **`operator` SPA env** (build time) | `ui.*` block written into the operator's Vite env at build | `compose.yml` build step exports `VITE_CLIENT_CONFIG=$(cat clients/$CLIENT_ID/client.yaml | yq -o=json '.ui')` |

`enterprise.id` and `enterprise.topic_prefix` continue to flow through the existing `ID_ENTERPRISE` env var (no change to how flows consume them via `env.get('ID_ENTERPRISE')`).

### What stays in Secrets Manager / GitHub Secrets

- `API_KEY` (edge-api auth)
- `FIREBASE_API_KEY` (or emulator placeholder per ADR-0002)
- `HASURA_ADMIN_SECRET`
- `RABBITMQ_PASSWORD`
- `SERVICE_ACCOUNT` (GCP JSON for PubSub)
- AWS-side rotation continues to work as today

The hard split: **declarative** (committed to git, code-reviewed, versionable) vs **secret** (never in git, rotated independently).

---

## Consequences

### Positive
- **One file per client.** Onboarding a new client = `cp -r clients/_template clients/newclient`, edit a YAML, PR review, deploy.
- **Equipment topology is version-controlled.** No more "we added L7 last month, forgot to commit, ops team can't reproduce." Adding a machine = PR against the YAML, deploy reseeds `packml_register`.
- **Per-client diffs are readable.** `diff clients/cpack/client.yaml clients/neopac-wil/client.yaml` shows the actual variation.
- **CS engineers get a real onboarding workflow.** Template file + schema docs + PR-based review beats "ask the on-call engineer which DB to edit."
- **transform_flows.py becomes a thin consumer** rather than a sprawling rewriter — most of its current logic (hardcoded URLs, Firebase key) moves into the YAML's `cloud.*` block.

### Negative
- **Schema migration is non-trivial for existing clients.** Each live client needs their existing scattered config (GitHub Secrets, packml_register, compose env) reverse-extracted into a YAML. Inventory + validation + ops sign-off per client.
- **The seed-equipment step is risky on existing prod data.** Idempotent UPSERT means a typo in the YAML could overwrite a production row. Needs careful schema constraints + a dry-run mode.
- **Drift between YAML and live DB becomes a new failure mode.** If someone INSERTs a row in `packml_register` manually (bypassing the YAML), the next deploy's seed pass could revert it. Needs a `--source-of-truth=yaml|db` toggle for transition.
- **Operator UI customization gets more visible** — labels in YAML means translators / customer-success teams need to edit YAML. Either we accept that (and document the workflow) or build a small admin UI later.

### Mitigations
- **One-client-at-a-time migration.** Migrate CPACK first (we know it best), validate for 2 weeks, then SimCorp, then Neopac. No big-bang.
- **Seed-equipment is opt-in.** Default OFF; explicitly enable per-client once the YAML is verified to match live state. Use `--dry-run` to print diffs before applying.
- **Schema validation.** A `make validate-clients` target runs JSON Schema validation on every YAML in `clients/`; pre-commit hook + CI check.
- **Read-only `enterprise.id` constraint.** Editing `enterprise.id` for an existing client is a fast-path to data corruption. The validator rejects diffs that change this field (must be a separate ticket + explicit override).

---

## Alternatives considered

### A. Per-client git branch (`client/cpack`, `client/neopac-wil`)
- ✅ Each client's full repo state is independently versioned; can pin different edge-nodered versions per client
- ❌ Branch sprawl; comparing configs across clients requires git checkouts
- ❌ Merges from `staging` → per-client branches get tedious; conflict surface compounds
- **Why not chosen:** Per-client subdirectory in a single branch gives the same isolation with much less git ceremony.

### B. External per-client git repos (`packiot/edge-config-cpack`, etc.)
- ✅ Full administrative isolation; can grant per-client CS team access
- ❌ N repos to keep in sync with edge-nodered version; deploy workflow needs to pull from two repos
- ❌ Drift between edge-nodered's expected schema and a per-client repo's actual schema can sit unnoticed
- **Why not chosen:** Premature isolation. Subdirectories work for 5-20 clients; revisit when we hit 50+.

### C. Database-as-config (everything in a `client_config` table)
- ✅ Easy runtime changes (no redeploy needed for a label tweak)
- ✅ Existing DB infrastructure
- ❌ No version control, no PR review, no rollback
- ❌ Bootstrapping a new client requires a DB superuser session — wrong on-ramp for CS engineers
- **Why not chosen:** YAML-in-git matches the "infrastructure as code" philosophy we've been building all month (Terraform, compose, ADRs).

### D. Status quo (sprawl)
- ✅ Zero migration cost
- ❌ Every problem this ADR solves persists
- ❌ Onboarding latency grows linearly with each new client
- **Why not chosen:** The sprawl is already painful at 3 clients; it gets worse at 10.

---

## Implementation phases

| Phase | Scope | Effort | Risk |
|---|---|---|---|
| **0 — Design + ADR** | This document | done | N/A |
| **1 — Schema + template + validator** | Define JSON Schema for `client.yaml`; write `_template/client.yaml`; add `make validate-clients` + CI check. No deploy changes yet. | 3-4 days | Trivial |
| **2 — Extract CPACK config** | Reverse-extract today's CPACK config from packml_register / GitHub Secrets / compose env into `clients/cpack/client.yaml`. Validate. Commit. Verify the YAML matches live state via a `make diff-client` dry-run. No deploy behavior change. | 1 week | Low |
| **3 — Wire transform_flows.py to read the YAML** | Extend `transform_flows.py` to read `clients/$CLIENT_ID/client.yaml` and use it for the URL-rewrite + gateway-derivation logic that's currently per-client-hardcoded. Existing env vars still work — YAML is *additive*, not replacing yet. | 1 week | Low |
| **4 — Wire db-migrate-client + operator UI** | New compose service + Vite env injection. Equipment seed is **dry-run only** for first week — logs the diff but doesn't UPSERT. After ops sign-off, flip to apply mode. | 2 weeks | Medium (touches live DB) |
| **5 — Migrate remaining clients** | One client per week. Each migration is a separate PR. | ongoing | Low (proven by CPACK) |

---

## Open questions

1. **YAML vs JSON vs HCL.** YAML is most readable; JSON is most tooling-friendly; HCL pairs with Terraform. YAML wins on human-edit-frequency, JSON wins on programmatic-validation-frequency. Probably YAML + auto-converted-to-JSON-for-tools.
2. **Schema versioning.** Need a `schemaVersion: 1` field so future schema changes are detectable. Bump procedure?
3. **Equipment ID space.** The YAML declares `id: 47` for staging CPACK's L5. Is the ID assignment **per-client autonomous** (each client gets their own 1..N range) or **globally unique across all Packiot clients**? Affects how the seed handles conflicts.
4. **Operator labels — localization.** If `ui.language: pt-BR`, do `labels.welcome` strings switch automatically based on browser locale, or is the YAML's `language` field authoritative? Multi-language story TBD.
5. **Drift detection.** Post-migration, how do we detect that someone manually INSERTed a packml_register row that doesn't exist in YAML? Periodic comparison script? Hasura subscription that alerts on packml_register changes?
6. **Per-environment overrides.** Should `clients/cpack/client.yaml` have `staging:` and `production:` sub-sections, or do we ship two files (`client.staging.yaml`, `client.prod.yaml`)? Affects ADR-0003's compose.production.yml.
7. **Seed-equipment safety on prod DB.** Per [the SELECT-only prod rule](feedback_prod_db_readonly.md), we never write to prod DB from this stack. So phase 4's UPSERT only ever targets staging DB and the future new-prod-DB (out of scope). Confirm + document.

---

## References

- [`edge-node-red/transform_flows.py`](../../edge-node-red/transform_flows.py) — current build-time rewriter; phase 3 extends this
- [`edge-node-red/.github/workflows/enterprise-neopac-wil-deploy.yml`](../../edge-node-red/.github/workflows/enterprise-neopac-wil-deploy.yml) — existing per-client deploy that this ADR's CLIENT_ID env var fits into
- [`edge-node-red/.github/workflows/deploy-template.yml`](../../edge-node-red/.github/workflows/deploy-template.yml) — the template that consumes the per-client GitHub Secrets today
- [[ADR 0003]] — production deployment of parent stack (the prod env this config applies in)
- [[ADR 0005]] — edge-nodered self-hosted runner deploys (the deploy chain that consumes this config)
- [Twelve-Factor App III. Config](https://12factor.net/config) — separates config from code; this ADR is a project-specific application of the principle
