# ADR-0050 — Rename the "F3" plane label to "analytics" (+ deploy-facing env cutover plan)

Status: Accepted (safe parts landed) · Env cutover: PLANNED (staged, not yet executed)
Date: 2026-08-21
Supersedes labelling from: ADR-0032 (F1→F3 flow collapse)

## Context

During the multi-flow migration (ADR-0032) we ran three parallel read/write
planes labelled by flow number:

| Legacy label | DB | Status |
|-------------|-----|--------|
| **F1** | `packiot` (`public`) | legacy operational plane — retired as the go-forward target |
| **F2** | `shadow_go_port` schema | comparator plane — **DROPPED** in ADR-0032 Step 5 |
| **F3** | `packiot_analytics` (`public`) | the go-forward end-state — **the only live analytics plane** |

The migration is over. F2 is gone; F1 is legacy. Only the former "F3" plane
remains, and its DB was already renamed `packiot_shadow` → `packiot_analytics`.
The "F3" flow-number label is now misleading — new engineers read "F3" and look
for an F1/F2 that no longer matter. We standardise the label to **`analytics`**
(dropping the flow-numbering) so the code and docs name the plane by what it *is*,
not by its position in a migration that has completed.

**F1/F2 references are left intact as historical record** — ADRs, migration
runbooks, parity-check scripts, and the `bake`/`comparator` F1↔F3 machinery
document how we got here. Renaming those would rewrite history and add noise.
The change is narrow: **standalone "F3" (meaning the current plane) → "analytics".**

## Decision

Rename in three buckets, by blast radius:

- **(a) Comment / doc prose** — SAFE, done now. Service READMEs that annotated the
  live plane as `packiot_analytics (F3)` or "writes F3 rows" now say "analytics
  plane". F1↔F3 comparator/historical phrases untouched.
- **(b) Internal-only identifiers** (not crossing a process boundary) — SAFE, done
  now. In `services/read-api/cmd/refdata-api`, the package-private `flowF3` const
  and `sqlF3` struct field were renamed to `flowAnalytics` / `sqlAnalytics`. The
  **wire value `"f3"` was NOT changed** — that is the `REFDATA_FLOW` env value
  (bucket c). `flowF1` kept as legacy.
- **(c) Deploy-facing env var KEYS / config values** — RISKY, DEFERRED. Renaming a
  KEY that is read from `.env` / compose / Secrets requires a coordinated cutover
  across the running fleet. Blindly renaming would strand the running deploy
  (unset var → silent fallback). Handled by the alias-first plan below.

## Deploy-facing env vars — alias-first cutover plan (DEFERRED)

Two env vars are actually read by code (both in `read-api`/`refdata-api`), plus
one config VALUE. This mirrors how the service rename was staged: add the
new name reading with fallback to the old, flip `.env`/compose, then drop the old.

| Current KEY / VALUE | Read at | New name | Notes |
|---------------------|---------|----------|-------|
| `REFDATA_FLOW` = `f3` | `main.go` `resolveFlow(os.Getenv("REFDATA_FLOW"))` | value `f3` → `analytics` | KEY stays `REFDATA_FLOW`; only the *value* modernises. `f1` stays. |
| `DB_NAME_F3` | `flow.go` `getenv("DB_NAME_F3", "packiot_analytics")` | `DB_NAME_ANALYTICS` | KEY rename. |

Set in `compose.staging.yml` (`REFDATA_FLOW: f3`, `DB_NAME_F3: packiot_analytics`)
and `compose.production.yml` (`REFDATA_FLOW: f3`, `DB_NAME_F3: ${POSTGRES_DB}`).

### Step-by-step (per var, reversible at every step)

1. **Add alias in code (additive, zero-behaviour-change).**
   - `resolveFlow`: accept `"analytics"` as a synonym for `"f3"`
     (`if raw == "f3" || raw == "analytics" { return flowAnalytics }`).
   - `dbNameForFlow`: read the new KEY first with fallback to the old
     (`getenv("DB_NAME_ANALYTICS", getenv("DB_NAME_F3", "packiot_analytics"))`).
   - Deploy. Nothing changes: existing `.env` still supplies `f3` / `DB_NAME_F3`.
2. **Flip the compose/`.env`/Secrets** to the new names
   (`REFDATA_FLOW: analytics`, `DB_NAME_ANALYTICS: …`). Redeploy staging, verify
   `/health` + a refdata dataset read against `packiot_analytics`, then prod.
3. **Drop the old aliases** from code (remove the `"f3"` branch and the
   `DB_NAME_F3` fallback) once both fleets run the new names. Deploy.

### Also-deferred (lower priority — dev-time helper scripts, not fleet env)

Local script env vars carrying the F3 label — not read by any deployed service,
so they can be renamed opportunistically alongside their scripts (or left, since
those scripts are ADR-0032 parity/fidelity tooling that documents the migration):
`F3_DB`, `F1_DB`, `F3_TARGET_DSN` in `scripts/adr0032-f3-fidelity-check.sh`,
`scripts/prod-knex-f3-reconcile-check.sh`, `services/read-api/scripts/refdata-f3-parity-check.sh`.

## Explicitly NOT renamed

- The `packiot_analytics` DB name — already correct (was `packiot_shadow`).
- `POSTGRES_ANALYTICS_*` env vars — already carry the correct name.
- ADRs, migration runbooks, `db/init-f3/`, parity scripts, `F3_MISSING` gate
  tokens, compose migration-journey comments — historical record.
- The `bake` / `comparator` F1↔F3 comparison identifiers — migration machinery,
  meaningless without the flow numbers.
- F3 references in sibling repos (`front4` "F3 data-hook" ADR-0029 comments,
  `edge-api` "prod / F3-local schemas" comment) — out of scope for this repo's
  PR; track separately if desired.

## Consequences

- New readers see `analytics` for the live plane; migration history stays legible.
- The env cutover is a follow-up with its own PR — no deploy-facing KEY moved here.
- `read-api` build + tests stay green (internal-only identifier rename).
