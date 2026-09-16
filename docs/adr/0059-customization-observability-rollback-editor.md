# ADR-0059 — Customization observability, rollback, and the Tier-2 editor round-trip

**Status:** Proposed · **Date:** 2026-09-15 · **Scope:** the infrastructure the ADR-0058 P3.2 / P3.3 phases need — (a) **observability** of active customizations + their runtime health, (b) **rollback** via descriptor version history, (c) the **Tier-2 Node-RED editor round-trip** (import a flow's customizations back into the descriptor). · **Altitude:** the implementation architecture for ADR-0058 Phase 3; it does NOT change the customization model (that is ADR-0058), it builds the governance instrumentation around it.

**Why this ADR exists.** ADR-0058 P3.3/P3.2 were deferred not for lack of design but for lack of *substrate*: the deriver drops a bad expr silently (no health signal), `client_descriptors` stores a version **counter** but no prior **content** (nothing to roll back to), and the ADR-0057 editor has no descriptor round-trip. This ADR specifies each missing piece so P3.2/P3.3 become straightforward implementation, not invention.

---

## 1. Observability (ADR-0058 P3.3a)

### 1.1 Runtime health — the expr-error signal
**Problem.** `deriver.Process` degrades a bad expr / non-finite result to a dropped tag (ADR-0058 fault isolation) — correct for the data plane, but the operator gets NO signal that a customization is silently producing nothing.

**Design — a Prometheus counter on the agent (the lightest correct substrate; the agent already exposes `/metrics`):**
```
agent_derive_errors_total{tenant, segment, kind}   // kind = expr_eval | non_finite
agent_derive_emitted_total{tenant, segment, kind}  // kind = integral | sum | expr
```
- The deriver takes an optional `Metrics` sink (a tiny interface, nil-safe) set at `New`; `Process` bumps `errors_total` where it currently `continue`s on an eval error / non-finite, and `emitted_total` when it appends synth. No behavior change; pure instrumentation.
- These scrape into the existing agent Prometheus registry → the platform's metrics stack. An "expr producing 0 while its inputs flow" is now `errors_total > 0` (or `emitted_total == 0` while inputs arrive) — an alertable, per-tenant, per-segment signal.
- **Foundation increment shipped with this ADR:** the counter fields + wiring in the deriver (bounded, testable). The scrape/alert wiring is ops config.

### 1.2 Active customizations — a read view
The simulate endpoint already returns `derived_rules` for a draft. For a *deployed* tenant, add read-api / edge-api `GET /api/onboarding/customizations` → the active derive rules (from the stored descriptor) + their last-emitted timestamp (from `agent_derive_emitted_total` age or a `silver.equipment_values` probe on the emit leaf). csadmin renders an "Active customizations + health" panel. No new storage — it joins the descriptor (rules) with metrics (health).

---

## 2. Rollback (ADR-0058 P3.3b)

**Problem.** `client_descriptors` bumps a `version` integer on each upsert but overwrites the JSONB — the prior content is gone, so "roll back" has no target.

**Design — an append-only version-history table + two endpoints:**
```sql
CREATE TABLE client_descriptor_versions (
  id             bigserial PRIMARY KEY,
  id_enterprise  int  NOT NULL,
  version        int  NOT NULL,           -- the client_descriptors.version at snapshot time
  descriptor     jsonb NOT NULL,          -- the full content AS STORED
  status         text NOT NULL,           -- lifecycle status at snapshot time
  acting_user    text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id_enterprise, version)
);
```
- **Write:** `UpsertDescriptorService` (edge-api) inserts a snapshot row **in the same tx** as the current-row update — every authored version is retained. (A retention policy — keep last N / 90 days — is an ops follow-up; content is small JSONB.)
- **Read:** `GET /api/onboarding/descriptor/versions` → `[{version, status, acting_user, created_at}]` (metadata only; content on demand via `?version=`).
- **Revert:** `POST /api/onboarding/descriptor/revert {version}` → copies that snapshot's `descriptor` into the current row as a NEW version (revert is forward-only — never rewrites history), status → `draft` (a reverted descriptor must be re-validated/generated before cutover). Audited via UserLogs.
- **UI:** a "History" section in the review step — list versions, "Restore" a prior one (with a confirm), then the normal generate/simulate/cutover flow re-validates it.

**Why forward-only revert:** rolling back by *appending* a copy (not deleting versions) keeps the audit trail intact and makes revert idempotent + safe — the same discipline as the medallion's append-only design.

---

## 3. Tier-2 Node-RED editor round-trip (ADR-0058 P3.2)

**Problem.** ADR-0057 gives a CS engineer the embedded Node-RED editor on a nodered-model box, and the `onboard-gen` renders `descriptor.customizations` ONTO the flow's `<Tenant> customizations` tab — but edits made IN the editor never flow BACK to the descriptor SSoT, so they're lost on the next generate (config-not-code drift).

**Design — a bounded import (editor → descriptor), never a blind sync:**
- **Export from the box:** the ADR-0057 broker already reverse-proxies the box Node-RED; add a broker call to fetch the flow JSON (`GET :1880/flows`, admin-scoped). 
- **Extract:** filter to the nodes whose `z` (tab) is the `<Tenant> customizations` tab (the same tab `generate_reader.go` re-homes onto), strip the runtime `z`/wiring the generator re-assigns, and produce a candidate `customizations[]`.
- **Validate + diff:** run the extracted nodes through the SAME `validateCustomizations` (ADR-0058 P2.3 bounds) and show a **diff vs the stored `descriptor.customizations`** — the engineer explicitly accepts the import (never an automatic overwrite of the SSoT).
- **Write:** on accept, set `descriptor.customizations` + re-version (feeds the P3.3 history). The next generate re-renders them onto the box — round-trip closed.
- **Guardrail:** only nodes on the customizations tab are imported; nodes the generator owns (the reader/tee flow) are never pulled into the descriptor. This keeps the descriptor the SSoT and the generated flow reproducible.

---

## 4. P4.3 (OEE math) — out of scope here
`#257 scrap_measurable → gold OEE Quality` is a separate, gated change (ADR-0058 epic P4.3); it needs its own PR with an adversarial OEE-parity hardproof. Not part of this observability/rollback/editor architecture.

---

## 5. Rollout
1. **Deriver error/emitted counters** (foundation — shipped with this ADR; agent-only, testable). ← done here
2. **Version-history table + snapshot-on-upsert + list/revert endpoints** (edge-api + a DB migration). Independent of 1.
3. **Editor round-trip import** (edge-api broker fetch + extract/validate/diff + csadmin accept UI). Depends on ADR-0057 (shipped).
4. **csadmin panels**: History (revert), Active customizations + health. Depend on 1+2.

Each is an independently shippable PR; none changes the ADR-0058 customization model or the data plane.
