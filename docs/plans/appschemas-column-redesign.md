# App-Schemas Column-Level Redesign — proposals (identity / config / ops / customer_reports / serving / bi)

Staging `packiot_analytics` review. Scope: the six "app-plane" schemas only (core/gold/silver/bronze/histdb
owned by siblings). One SAFE win was implemented (see bottom); everything below is CUTOVER — proposed, not
executed, because each touches a live consumer contract (read-api `SELECT *`, Superset RLS, edge-api writers,
external SAP/Montebello sync, or a prod-parity-tracked object).

Grounded in live catalog + row/column population + a full grep of `services/`, `edge-api/src`, `front4/src`,
`edge-node-red`. Consumer roles: **read-api** connects as `postgres` (BYPASSRLS, app-layer `id_enterprise=$1`
fence); **Superset** goes through `bi.*` (owner `bi_owner`, NOBYPASSRLS → RLS-respecting); **edge-api** is the
users/config/audit write plane; **stream-engine** writes PO-control + event-justify rows into `identity.user_logs`.

---

## P1 — `serving.*` views are SECURITY DEFINER owned by `postgres` (BYPASSRLS) → zero RLS defense-in-depth

**Finding.** All 9 `serving.*` views are owned by `postgres` (`rolbypassrls=t`, `rolsuper=t`) and none set
`security_invoker`. A default (definer-semantics) view evaluates the *owner's* RLS context, so any role that can
`SELECT` a serving view — including a future NOBYPASSRLS consumer — silently bypasses every RLS policy on the
underlying `core`/`gold`/`silver` tables. Contrast `bi.*`: owner `bi_owner` is NOBYPASSRLS, so those views *do*
honour RLS (this is the real "bi vs serving = RLS-safe vs RLS-bypassing" split; it lives in the view *owner*, not
in a reloption). Today the exposure is masked because the only serving-view consumer (read-api) already connects
as BYPASSRLS postgres and fences with `WHERE id_enterprise = $1`. It becomes a live tenant-leak the moment a
serving view is exposed to a NOBYPASSRLS role (e.g. the `cloudbeaver_ro`/`read-api NOBYPASSRLS` hardening in
t276/#264, or Superset ever pointed at `serving.*`).

**Current → proposed.** `ALTER VIEW serving.<v> SET (security_invoker = on);` on the tenant-scoped views
(`v_entities_per_user_role[_operator]`, `v_menu_per_user_role`, `v_operator_*`, `v_events_2`, `v_report_downtimes`,
`production_information`), **or** reassign their owner to a NOBYPASSRLS role. Prefer `security_invoker=on` — it is
the modern PG15+ idiom and needs no ownership churn.

**Consumers.** read-api (all serving views), edge-api (authz views). **Risk.** With `security_invoker=on` the
querying role must hold direct `SELECT` on the base tables AND its own RLS predicates now apply — read-api as
postgres is unaffected (BYPASSRLS + owns nothing changes), but any RLS-forced consumer starts getting row-filtered.
That is the *point*, but it must be validated per consumer before flipping.

**Expand/contract.** (1) grant base-table SELECT to serving consumers if not already held; (2) flip
`security_invoker=on` one view at a time; (3) hardproof each: query as postgres (unchanged rowcount) and as a
NOBYPASSRLS test role (now RLS-filtered); (4) roll back per-view with `SET (security_invoker = off)`.

---

## P2 — `bi.*` / `serving.*` views expose magic-number status columns without labels

**Finding.** The design already labels some coded columns (`equipment_label` decodes `tp_equipment` 1/2/3;
`po_label` composes a display name). But status/type integers are still exposed raw:
- `bi.production_orders.status` — PO lifecycle int (1=available, 2=running, 3=finished, 4=paused). No `status_label`.
- `bi.oee_shift` / `bi.oee_hourly` — fine (numeric OEE only).
- `serving.v_events_2.event_type` (1=auto event / 2=manual `equipment_events_man` / 3=…) and `.status`
  (equipment-status code; `<> 6` = "not running" filter is inlined as a bare literal) — both raw.

Every downstream (front4, Superset) re-implements the same 1/2/3/4 → label mapping. Centralising it in the view
removes drift.

**Current → proposed.** Add sibling `*_label` columns via `CASE` (additive, existing raw column untouched), e.g.
`CASE po.status WHEN 1 THEN 'available' WHEN 2 THEN 'running' WHEN 3 THEN 'finished' WHEN 4 THEN 'paused' END AS
status_label`. Do NOT rename/drop the raw column.

**Consumers.** read-api (`bi.production_orders`, `serving.v_events_2`), Superset (`bi.*`). **Risk.** Low — additive
column. Contract-golden tests in read-api (`testdata/contract.golden.json`) will need re-baselining.
**Expand/contract.** Additive column → re-baseline golden → ship. Reversible by dropping the added column.

---

## P3 — `config.language_packs`: legacy per-blob i18n vs `config.translations` normalized (ADR-0048)

**Finding.** `translations` (2124 rows, PK `(language_tag,app,namespace,key)`) is the normalized i18n store;
`tenant_translations` (0 rows) is its per-tenant override layer — this is the ADR-0048 direction. `language_packs`
(5 rows) is the *legacy* monolithic design: one row per language with six wide jsonb blobs
(`language_pack_desktop/mobile/operator/overview/operator40` + legacy `id_language_pack`). Population shows the
model is already half-dead as *data*: `mobile`, `operator`, `overview` blobs are **0/5 populated**; only `desktop`
(5/5) and `operator40` (2/5) carry anything. BUT the table is **not dead as an object**: read-api serves it as a
live dataset (`SELECT * FROM language_packs`, `main.go:147`) and via `enterprises.language_packs`, and edge-api has
a full read/write DAO. So the empty jsonb columns cannot be dropped safely today — `SELECT *` would change the
served contract and break the read-api contract-golden.

**Current → proposed.** Two-step: (1) migrate the last live consumers (front4 i18n, operator40) off
`language_packs` onto `translations`/`tenant_translations`; (2) then retire `language_packs` (or at minimum drop
the three always-empty blobs). Until (1) lands, treat every `language_packs` column as load-bearing.

**Consumers.** read-api (dataset `language-packs` + `enterprise-config`), edge-api DAO, front4. **Risk.** High —
touches the live translation-serving path. **Expand/contract.** Dual-read (translations first, language_packs
fallback) → cut writers → verify zero reads via `pg_stat_statements` → drop. Classic multi-service de-shim.

---

## P4 — `config.dashboard_config` vs `identity.user_screen_config` overlap

**Finding.** Two near-identical layout stores. `dashboard_config` (2 rows, PK
`(id_enterprise, dashboard_id, version)`, `config jsonb`, versioned — "the highest version is served") is the
tenant **baseline**. `user_screen_config` (0 rows, unique `(id_enterprise, id_user, screen)`, `config jsonb`,
`updated_at` — not versioned) is the per-**user** override, where `screen == dashboard_id` when overriding a
baseline. They live in *different schemas* (config vs identity) despite being the same concern at two scopes, and
one is versioned while the other is last-write-wins.

**Current → proposed.** Not a merge candidate (tenant-baseline vs user-override is a legitimate two-table split),
but the design should be made consistent: either add versioning to `user_screen_config` or document the deliberate
asymmetry; and consider co-locating both in `config` (move `user_screen_config` → `config`) since both are
presentation config, not identity. Purely organizational — defer until there's write traffic (both ~empty now).

**Consumers.** read-api (`user_screen_config` 64KB-guarded upsert), front4. **Risk.** Medium (schema-qualified refs
in read-api). **Expand/contract.** Rename/move via `SET SCHEMA` + transient shim view → repoint read-api → drop shim.

---

## P5 — `identity.users.user_roles` — misleading plural name for a scalar int FK

**Finding.** `users.user_roles integer` is a **scalar** FK → `identity.user_roles.id_user_role` (single role per
user), but the plural name reads like an array/join column. `col_description` already documents this ("Scalar int
despite the plural name"). Pure readability debt.

**Current → proposed.** Rename `users.user_roles` → `id_user_role` (matches the FK target's PK name and the
platform's `id_*` convention). **Consumers.** edge-api (`users-dao.ts` SELECT/INSERT/UPDATE list `user_roles`),
read-api (`datasets.go:741` selects `user_roles`, contract-golden line 1177 area). **Risk.** Medium — a bare column
rename breaks both apps + the golden. **Expand/contract.** Add `id_user_role` as a generated/synced column →
repoint edge-api + read-api + re-baseline golden → drop `user_roles`. Not worth it standalone; batch with any other
`identity.users` change.

---

## P6 — `identity.user_logs.cd_user` — legacy dead column

**Finding.** `cd_user integer` ("legacy numeric user code") is **0/31285 populated**, has **zero writers and zero
readers** in all four codebases (only appears in `edge-node-red/db/00-schema.sql`, the legacy DDL). The other
"extra" columns the doc-pass flagged are NOT dead — I traced live writers: stream-engine
`pocontrol/setup_userlog.go` (`userLog30880`) and `events_justify.go` (`ujUserLog`) both INSERT
`id_site, id_area, subcategory, description, ip` explicitly; they read 0/31285 today only because those SparkPlug
PO-control/justify flows haven't fired on staging. So **only `cd_user` is a genuine drop candidate.**

**Why not SAFE.** `user_logs` is a prod-mirrored audit table; `cd_user` exists in the prod/legacy schema and the
f3-schema-parity machinery tracks column parity. A staging-only drop diverges from prod. Classify CUTOVER: drop
from prod DDL + staging together, or leave as harmless legacy ballast.

**Consumers.** none. **Risk.** Low functionally, but parity-tracked. **Expand/contract.** Trivial `DROP COLUMN` +
rollback `ADD COLUMN`, coordinated with the prod/legacy DDL owner.

---

## P7 — `ops.mirror_replay_dlq.retry_attempts` — missing non-negative CHECK

**Finding.** `retry_attempts integer NOT NULL DEFAULT 0` drives exponential backoff `(1 << retry_attempts)` minutes.
A negative or absurdly large value would break backoff (huge shift → overflow/UB-ish interval). All 1374 live rows
satisfy `>= 0`. A `CHECK (retry_attempts >= 0 AND retry_attempts <= 30)` would be additive and currently-satisfied.

**Why not implemented as SAFE.** The table has an active writer (the DLQ retrier, `mirror-worker main.go:413` +
the retrier loop). A CHECK on a live-written table risks a write failure if the retrier ever legitimately exceeds
the ceiling. Confidence that it can't is high but not proven → PROPOSE per the "unsure → PROPOSE" rule.
**Expand/contract.** Add `CHECK ... NOT VALID` → `VALIDATE CONSTRAINT` → observe retrier. Reversible via
`DROP CONSTRAINT`.

---

## P8 — `customer_reports` internal-bookkeeping redundancy (flag only; external contract)

**Finding.** `customer_reports.*` columns are external SAP (Neopac/German) + Montebello contracts — **not to be
renamed/retyped.** Internal-only redundancy worth a note (do NOT touch the external-facing report columns):
- `production_data_sync`: `indice_geral`/`prev_indice_geral` (rolling index + prior) and
  `trans_status`/`final_trans_status` (transient + terminal) are internal sync bookkeeping; `logics integer` is an
  unlabeled magic control-code. Timestamp sprawl: report-shape `createddate`/`updateddate` vs packiot-side
  `ts_creation`/`last_update`/`real_update` — five timestamps, overlapping semantics.
- `boxes` is the internal table here (customer_id=6 SAP-transform source); its shape is clean.

**Proposed.** Document `logics` code values (`COMMENT`); no structural change — the pool's column set is dictated by
the external transfer contract and the stream-engine report writers. Flag only.

---

## IMPLEMENTED (SAFE) — recorded here for completeness

**Duplicate partial-unique index on `identity.users(id_user_cognito)`.** Two byte-identical indexes existed —
`users_id_user_cognito_un` (from edge-node-red bootstrap SQL `32-`/`41-`) and `users_id_user_cognito_uniq` (from
edge-api knex migration `20260809000002`, the parity-tracked canonical). Dropped `_un`, kept `_uniq`.
Migration: `db/migrations/tRD-appschemas-dedup-cognito-index/` (01 + rollback).
Hardproof: after the drop, a duplicate `id_user_cognito` INSERT is still rejected by `_uniq`; the sole writer
(`cognito-users-dao.ts`) uses `INSERT … WHERE NOT EXISTS` (not `ON CONFLICT`), so nothing referenced either index
by name. Both indexes were `idx_scan=0` (9-row table). **Follow-up:** edit `edge-node-red/db/32-cognito-user-id.sql`
+ `41-front4-f3-cognito-seed.sql` to stop creating `_un`, so a fresh bootstrap doesn't reintroduce the dup.
