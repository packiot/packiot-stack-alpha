# ADR-0056 — One application DB with schemas, not a control-plane split

**Status:** Accepted (2026-09-09)
**Context supersedes the informal "packiot vs packiot_analytics" 2-DB topology.**

## Context

The medallion reorg (#237/#241, ADR-0045) consolidated *all* application data into the single
`packiot_analytics` database, separated by **schema, not by database**:

- **Analytics plane:** `bronze` / `silver` / `gold` / `serving` / `bi` (medallion pipeline + read surface)
- **Control plane:** `core` (conformed dimensions), `auth` (identity), `config` (i18n/labels), `ops` (plumbing)
- `public` (transactional + compat shims)

This raised a fair question: **should `auth` (identity) live in a database literally named
`analytics`?** And more broadly — should the control plane be split into its own physical DB
("more mature")?

The instance `10.10.10.89` also still hosts the **legacy monolith `packiot`** (557 tables, 3.8 GB,
telemetry+auth+everything) — now dead weight on staging (telemetry frozen 2026-08-16), retirement
owned by the gated packiot40 cutover (#225). (`authentik` was a retired IdP DB — dropped
2026-09-09; identity is Cognito.)

## Decision

**Keep the single application DB. Do NOT physically split the control plane. Rename the DB to an
honest name (`packiot`) once the legacy monolith frees it. Keep the schema seam so a future split
is mechanical if ever justified.**

## Rationale

The real defect is the **name**, not the co-location. Schemas *are* the logical-separation tool;
`auth` in a *schema* is correct. `auth` in a DB named `analytics` is the smell — and `analytics`
is a fossil from when the DB was telemetry-only. It is now the whole app DB.

Splitting `auth`/`config` into a separate physical DB was considered and **rejected** — none of the
drivers that would justify it are present:

1. **No security-isolation driver.** Credentials live in **Cognito**, not the DB; `auth.users` is a
   profile/role-mapping table keyed to Cognito. There is no sensitive credential store to isolate.
2. **No scale/latency driver.** `auth` = 9 users, 3 roles; it will never contend with 6.4 GB of
   TimescaleDB.
3. **No ownership driver.** There is no separate identity service/team that should own its own DB.
4. **Coupling cuts against a split — and it's DB-level, not just app-level (the decisive finding).**
   `auth` is JOINED to `core` *inside the database* by the hot authz view
   `serving.v_entities_per_user_role` (the entity-scope check "which sites/areas/equipments may this
   user see"), which references BOTH `auth` (user_roles/users) AND `core` (areas/sites/equipments)
   and is evaluated on ~every front4/operator request. So the coupling is a transitive chain:
   `auth ⋈ core` (authz view) and `core ⋈ facts` (rollup dim joins). Splitting `auth` to its own DB
   turns that hot authz join into a cross-DB FDW join (slow/fragile on the login path) OR requires
   rewriting authz resolution app-side first — MORE work than the rename, for the same naming
   outcome plus a permanent cross-DB tax. `core` cannot move to an auth DB either (rollup pins it to
   facts). The three belong together. (Lesson: coupling hides in views/joins — two schemas look
   separable until you check what joins them; one authz view stitches identity into the warehouse.)

   The "keep the name by splitting auth out so packiot_analytics is analytics-only" alternative
   (considered 2026-09-09) fails for exactly this reason: `auth` is not separable from `core`.

Splitting for the *aesthetic* of separation is premature-separation over-engineering: every split
DB is a permanent tax (extra pool, backup/restore, monitoring, migration pipeline, loss of
cross-boundary transactions). The senior discipline is **defer complexity until a driver justifies
it, but architect so it's cheap later** (YAGNI). We already have that: the clean schema boundaries
are the pre-built seam.

## When to revisit (the split becomes the right call)

Revisit — and split `auth`/`config`/`ops` into a dedicated control-plane DB — if any of:
- a **compliance/SOC2** requirement to isolate identity data in its own boundary (separate
  access/backup/audit),
- a **dedicated identity/auth microservice** that should own its own datastore (Conway's law),
- **measurable contention** — analytics load (a big cagg refresh / TimescaleDB vacuum) demonstrably
  degrading auth/login latency.

Because `auth`/`config`/`ops` are clean schemas NOT joined by the rollup, the split at that point is
a near-mechanical `ALTER … SET SCHEMA` (into a new DB via dump/restore) + repoint the ~2 consumers
(edge-api, read-api) — not a rewrite. (Note: `core` should stay with the facts — it's joined by the
rollup.)

## Consequences

- **The rename `packiot_analytics` → `packiot`** is the one concrete action, and it is **gated on
  the legacy `packiot` DB being retired first** (#225) so the name is free. It is a disruptive
  cutover (connection strings across ~23 services + pgbouncer + tooling + Grafana/Superset
  datasources), so it must ride the **legacy-retirement window** and be done once, not piecemeal.
  Do NOT rename to an interim name (`packiot_app`) now — that would be two renames.
- Until then, `packiot_analytics` remains the honest home for all app data via schemas; the name is
  a known, documented misnomer, not a design error.
- Follow-up task: the gated DB rename (tied to #225).
