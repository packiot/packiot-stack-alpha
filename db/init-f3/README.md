# db/init-f3 — assemble the F3 schema as prod `public` (ROADMAP W1.4)

**The single highest-care correctness item for the bispharma prod go-live.**
Greenfield production runs ONE database whose `public` schema **is** the F3
(refactored single-flow) schema — the same schema staging's `packiot_shadow`
carries, but born directly instead of reached through the ADR-0012/0032
migration. **If `public` is not F3-shaped, the compute chain
(edge-transformer Go Calc → oeecloud-worker rollups → caggs → `uns_*`) runs and
produces SILENTLY WRONG OEE.** There is no error, no crash — just wrong numbers.

This directory is the DB-init path + the correctness gate that stops that.

| File | What |
|---|---|
| `MANIFEST.f3-target` | The authoritative F3 **target manifest** captured SELECT-only from live `packiot_shadow` (665 objects). The parity gate diffs against this. |
| `snapshot/` | Where the AUTHORITATIVE F3 schema-only DDL lives (see §4). **Gated / not yet populated.** `compose.production.yml`'s `db-schema-f3` one-shot applies `snapshot/*.sql`. |
| `assemble.sh` | The reviewable **fragment scaffold** — concatenates the canonical F3 source fragments in dependency order. Used to *author/understand* the schema. **Does NOT reach parity by itself** (see §3). |
| `../../scripts/prod-f3-schema-parity-check.sh` | The **gate**: diffs any candidate DB's `public` against `MANIFEST.f3-target`. |
| `../../scripts/capture-f3-snapshot.sh` | The **gated** producer of `snapshot/` — a curated schema-only dump of `packiot_shadow`. |

---

## 1. The target manifest (verified live, SELECT-only)

Captured from staging `packiot_shadow` (DB EC2 `i-064bb36d1c454d861`, `BEGIN READ ONLY`):

| Class | Count | Notes |
|---|---|---|
| Tables (`relkind r`) | **159** | incl. 5 raw hypertables, the `*_runtime_*` rollup grains, `uns_*` snapshots, `h_piot_*`/`h_*` analytics relations, `data_quality_event`, `downtime_reason` dim, `packml_register` |
| Views (non-cagg) | **20** | operator `v_operator_*`, refdata `v_report_downtimes`, `v_menu_per_user_role`, … |
| Continuous aggregates | **15** | `agg_{equipment,area,site}_values_{1min,10min,1hour}` + `ca_agg_*`, `ca_discrete_changes_1s`, `ca_equipment_boxes_*` |
| Hypertables | **5** | `equipment_values`, `equipment_events`, `*_raw`, `lab_equipment_values` |
| Functions/procs | **466** | of which **91 `h_piot_*`** (the served analytics library) + 40 `piot_*` (incl. the 17 `piot_create_*_runtime` provisioning fns the Go worker calls) |
| Also | | schemas `customer_reports` (4 tbl) + `customer_dashboards` (3 tbl) — the parameterized replacements for the old per-enterprise `report_*`/`c35_*` clones |

**Fidelity bar (ADR-0032 acceptance, matches `scripts/adr0032-f3-fidelity-check.sh`):**
≥ 91 `h_piot_*` functions + the 6 config relations (`oee_targets`, `scrap_targets`,
`dashboard_config`, `user_roles`, `v_menu_per_user_role`, `v_report_downtimes`),
and OEE anomaly-free (no `oee>1`, no `oee<0`).

> Note: `MANIFEST.f3-target` is a *superset* of the strict canonical F3 — live
> `packiot_shadow` has accreted staging debris that greenfield prod must NOT
> inherit: `ops_shadow_zombie_preimage_20260716`, `report_shift_enterprsie_06`,
> `report_speed_enterprsie_33`, `hasura_test`, `*_po_func_ret` snapshot tables,
> the `c33_/c35_` per-tenant dashboard views. §4's curation drops these.

---

## 2. Where the F3 schema actually comes from (the real lineage)

The roadmap §3.1 says F3 is "assembled from `edge-node-red/db/*.sql` plus the
oeecloud-worker rollup DDL." **That is incomplete and partly wrong** — verified
against the code and live `packiot_shadow`:

- **`edge-node-red/db/00-schema.sql` is a NON-RUNNABLE dump** — a captured psql
  introspection report (`TABLE: name | col type` lines), never executed. It is
  the *reference* files 17/19/20/21 were authored against, not a base DDL.
- **The real continuous-aggregate layer is NOT in `edge-node-red/db`.**
  `22-agg-views.sql` builds `agg_*`/`ca_*` as **plain real-time VIEWS** ("staging
  F1 has no hypertables"). F3 needs **real TimescaleDB continuous aggregates** on
  a hypertable `equipment_values` — those come from
  `docs/adr/reference/migrations/0012-f3-cagg-layer.sql` (+ `0012-d1-…`).
- **The oeecloud-worker owns NO DDL.** `internal/rollup/provision.go` sets
  `search_path` and calls pre-existing `piot_create_*_runtime` PL/pgSQL functions
  (verbatim) to POPULATE rollup grain rows. The tables + functions themselves
  come from the SQL files (`db/10`, `db/20`). The "schema-parameterization" is a
  `search_path` injection, not templated DDL. For F3, the injected schema is
  literally `public` (`flows.go`: F3 `Dest{EvSchema:"public"}`) — exactly the
  greenfield-prod target.
- **Base hierarchy DDL has no clean canonical file.** On legacy staging it came
  from edge-api knex (F1 shape); the dev `db/init/00-schema.sql` is real DDL but
  explicitly OMITS `agg_*` + `_quality` columns (incomplete).
- **F3-critical fixups live in `db/init/`:** `02-refactored-rollup-bigint-widen.sql`
  widens week/month aggregate int4→bigint (int4 SUM overflow denies the whole
  rollup UPDATE → stale OEE); `03-purge-nonstate-event-pollution.sql` is a data
  cleanup (no-op on empty).

**Ordered canonical fragment list** (what `assemble.sh` encodes; include/exclude):

1. extensions (`timescaledb`, `pg_cron`)
2. base hierarchy + reference (⚠ no clean file — dev `db/init/00-schema.sql`, incomplete)
3. `db/10` missing tables + rollup grains, `db/11` UNS tables
4. `db/17` Hasura stubs, `db/19` h_piot library + tracked fns, `db/20` OEE engine + provisioning fns, `db/18` FKs, `db/21` types, `db/09` column parity
5. `migrations/0012-phase3-writer-tables` raw hypertables, **`migrations/0012-f3-cagg-layer` real caggs** (NOT `db/22`)
6. read-plane: `db/23` gapfill+views, `db/04/05/06/07` operator/Hasura companions, `migrations/0018-f3-refdata-deps`, `db/27` refdata views, `db/28` dashboard_config, `db/29/30/31` F3 analytics/front4 ports, `db/32` Cognito, `migrations/0039-reasons-dimension`
7. `db/init/02` bigint-widen (`__SCH__`→`public`)

**EXCLUDE (must NOT enter greenfield prod):**
`db/00` (dump), `db/01`/`03-operator-simulator`/`13`/`16`/`24`/`26` (seeds/fixtures),
`db/08`/`14`/`15` (dev OEE-compute triggers — the Go worker + caggs own compute;
these would double-compute), `db/22` (plain-view cagg substitute), `db/25`
(mirror/replay — greenfield prod IS the source), and the entire proposed rename
map (`docs/audits/packiot-shadow-rename-map` is a PROPOSAL, **not applied** — keep
legacy names or the Go worker's string-literal SQL breaks at runtime).

---

## 3. Why the fragment path does NOT reach parity (measured)

Running `assemble.sh` against a fresh `timescaledb:2.25.2-pg16` container and
gating with `prod-f3-schema-parity-check.sh`:

```
TARGET(F3)    T=159 V=20 M=0 F=466 C=15 H=5   (total 665)
CANDIDATE     T=240 V=31 M=10 F=406 C=8  H=3   (total 698)
F3_MISSING = 344   EXTRA = 377   → FAIL
```

The candidate is **neither a subset nor a superset** of F3 — 79 F3 tables
missing while 160 extra, caggs 8/15, hypertables 3/5, and many same-named tables
with **different column fingerprints**. Root cause: the fragments were authored
against an *already-complete, already-populated* `packiot_shadow` (they reference
`production_orders_runtime`, `equipment_events_man`, `equipments.downtime_reasons`,
etc. that the incomplete dev base never creates), so concatenation cascade-fails.
**This is precisely the "silently wrong OEE" risk — and the gate catches it.**

Conclusion: **do not hand-assemble F3-as-public from fragments.** Use §4.

---

## 4. The AUTHORITATIVE method — curated schema-only snapshot of `packiot_shadow`

The only method that guarantees `prod public == staging F3` is to snapshot the
live F3 schema structurally and curate out the debris:

```sh
# GATED: read on staging DB EC2 (schema-only = read-only in effect; no data).
# Needs USER go per the SELECT-only directive. Produces db/init-f3/snapshot/.
./scripts/capture-f3-snapshot.sh
```

It runs, inside the staging `timescaledb` container:

```sh
pg_dump -U postgres -d packiot_shadow \
  --schema-only --no-owner --no-privileges --schema=public \
  --exclude-table='ops_shadow_zombie_preimage_*' \
  --exclude-table='report_*_enterprsie_*' \
  --exclude-table='*_po_func_ret' \
  --exclude-table='hasura_test' \
  --exclude-table='dt5min_po_function_returns' \
  --exclude-table='*_13_po_func_ret'
# + drop the c33_/c35_ per-tenant dashboard views; keep customer_dashboards.* /
#   customer_reports.* (the parameterized replacements) if the client uses them.
# + swap staging-tuned cagg refresh/retention policies for prod policies
#   (staging-parity-cagg-adoption.sql documents the staging divergence).
```

Split the dump into ordered `snapshot/NN-*.sql` files (extensions → tables →
hypertables → caggs → functions/views → constraints) so `db-schema-f3` applies
them deterministically. Then **prove it** (§5). A snapshot dumped FROM
`packiot_shadow` diffs to `F3_MISSING=0` by construction; the gate then also
guards against future drift.

---

## 5. The parity gate (correctness proof BEFORE any client data)

```sh
# candidate = the assembled prod-init DB (local container or, gated, prod public)
CANDIDATE_DSN='postgresql://postgres:pass@host:5432/packiot' \
  ./scripts/prod-f3-schema-parity-check.sh gate
# PASS ⇔ F3_MISSING = 0. Also run scripts/adr0032-f3-fidelity-check.sh for the
# live-DATA health bar (≥91 h_piot fns + 6 config relations + OEE anomaly-free).
```

The gate is the go/no-go for W5's dark-launch: **no client data flows into prod
F3 until F3_MISSING=0.**

---

## 6. Validated vs needs-the-real-DB

| Item | Status |
|---|---|
| Target manifest captured from live `packiot_shadow` (SELECT-only) | ✅ validated |
| Parity gate correctly FAILs an empty DB (F3_MISSING=562) and a partial assembly (344) | ✅ validated locally (`timescaledb:2.25.2-pg16`) |
| `compose.production.yml` `db-schema-f3` wiring + `docker compose config` | ✅ validated (exit 0) |
| Fragment-assembly divergence measured (F3_MISSING=344 + EXTRA=377) | ✅ validated locally |
| **Populate `snapshot/` via `capture-f3-snapshot.sh`** | ⛔ GATED — needs the staging DB read + USER sign-off (schema-only, read-only-in-effect) |
| Reconcile edge-api knex (must not rebuild F1 over F3) | ⛔ USER decision — see `compose.production.yml` db-migrate comment |
| End-to-end prod dry-run boot on empty F3 DB (W1.6) | ⛔ needs the snapshot + a deploy (do NOT run against prod) |
