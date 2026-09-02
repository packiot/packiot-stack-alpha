# edge-api knex ↔ F3-as-`public` reconciliation — ROADMAP W1.5

**Status:** BUILD + PROVE (design + gate + local validation). **Not applied to
prod. Not merged. Staging/prod SELECT-only.**
**Date:** 2026-07-27 · **Anchors:** [production-f3-schema-assembly](./production-f3-schema-assembly.md)
(W1.4) · [production-buildout-roadmap](./production-buildout-roadmap.md) §W1 ·
[ADR-0032](../0032-collapse-to-single-flow-f3.md) (F3).

Resolves the last correctness-critical item flagged by W1.4 (PR #628): edge-api's
knex migrations must NOT rebuild the legacy **F1** schema over the proven
**F3-as-`public`** schema in greenfield prod.

## The problem

Greenfield prod boots: `postgres` → **`db-schema-f3`** (assembles F3 as `public`,
proven `F3_MISSING=0`) → **`db-migrate`** (edge-api `knex migrate:latest`) →
edge-api. edge-api's 41 knex migrations were authored to build the **F1** schema
from an empty DB; the early ones are plain `CREATE TABLE x` with **no** guard.

Run against an F3-shaped `public` with an empty `knex_migrations`, knex tries to
apply **all 41 from scratch** and dies on the first one:

```
migration file "20230816170559_create_equipment_values.ts" failed
  create table "equipment_values" ("id_equipment" serial, ... ) - relation "equipment_values" already exists
```

Two failure modes, both fatal:
- **Snapshot present** → knex aborts the batch → `db-migrate` exits non-zero →
  boot halts (edge-api `depends_on` it). Loud, but prod can't start.
- **Snapshot absent** (F3 not built) → knex **succeeds** and silently builds the
  **F1** shape → the compute chain runs and produces **silently wrong OEE**.

Note the shapes genuinely differ: knex's F1 `equipment_values` is a plain table
with a `serial` PK; F3's is a TimescaleDB **hypertable**. A silent rebuild is
catastrophic, not cosmetic.

## The migration inventory (41) → three classes

Verified by reading every migration and probing a live F3 build:

| Class | Count | What | Disposition |
|-------|-------|------|-------------|
| **F3 already provides** | 18 | `equipment_values`, `equipments`, `enterprises`, `clients`, `sites`, `areas`, `product_families`, `products`, `user_roles`, `users`, `production_orders`, `production_orders_runtime`, `equipment_events`, `equipment_events_man`, `user_logs`, `packml_register` + `net_production_type` col + the PO check constraints | **fake-baseline** (plain CREATE/ALTER → would ERROR) |
| **F3 deliberately omits** | 7 | equipment_values→equipments FK; `production_orders_runtime` gist EXCLUDE; the `update_prev` **event trigger** + its `piot_trig_*` fn (×2 defs); the two `shadow_go_port` comparison schemas | **fake-baseline** (re-adding DIVERGES from F3; the trigger would *double-manage* event durations = wrong OEE) |
| **edge-api-specific, F3 lacks** | 16 | `labels`, `sample_boxes`, `scanned_boxes`, `idempotency_keys`, `mirror_replay_dlq` tables; `production_orders.id_label` + `users.operator_pw_hash` columns; + guarded no-ops (`shifts`, `pages`, `id_plc`, `active`, …) | **RUN** (net-new; edge-api reads/writes them at runtime) |

The three edge-api-lacks-in-F3 facts that decide the design:
1. F3 (`packiot_shadow`) uses `box_scans`/`box_production_bridges` (refactored),
   **not** the F1 `scanned_boxes`/`sample_boxes`/`labels` — but edge-api's DAOs
   still read/write the F1 names (`labels-dao.ts`, `samples-dao.ts`). Prod needs
   both: F3 for compute, F1-named tables for edge-api.
2. `production_orders.id_label` is INSERTed by `production-orders-dao.ts`; F3
   lacks the column → must be added or PO creation 500s.
3. `users.operator_pw_hash` is SELECTed by `session-dao.ts` for operator login;
   F3 lacks it → must be added or login errors.

So prod `public` is the **UNION** `F3 ∪ edge-api-operational` — not F3 alone.

## The fix — fake-baseline (industry standard)

`db/init-f3/knex-baseline.sql` pre-seeds `knex_migrations` with the 25
fake-baseline migrations (each annotated with *why*). This is the same move as
Rails `db:schema:load` + `db:migrate --fake` and Django `--fake-initial`: when
the schema is loaded from a dump, the migrations that built it are marked applied
so only *future* ones run.

knex 2.5.1's **only** integrity check is `validateMigrationList` →
`getMissingMigrations` = "a *completed* migration must exist on disk." It does
**not** reject a pending migration that sorts *before* a faked one, so faking a
non-contiguous subset is safe — the 16 pending (edge-api-only) migrations still
run, in filename order, in one batch. (We also seed `knex_migrations_lock` with
its single `is_locked=0` row, which knex's `_lockMigrations` requires.)

New one-shot **`db-knex-baseline`** runs between `db-schema-f3` and `db-migrate`.

```
postgres → db-schema-f3 → db-knex-baseline → db-migrate → edge-api
           (F3=public)    (seed 25 fakes)    (run 16)
```

## The proof

On a throwaway `timescaledb:2.25.2-pg16`, applying the real boot sequence
(`db-schema-f3` snapshot → `knex-baseline.sql` → `knex migrate:latest`):

```
knex baseline seeded: 25 rows
knex migrate:latest : "Batch 1 run: 16 migrations"        (exactly the RUN set)
```

Post-knex verification (`scripts/prod-knex-f3-reconcile-check.sh`):

```
CLASSIFICATION : 41 migrations = 25 fake + 16 run, no overlap        → PASS
COLUMN-INTEGRITY: target_cols=2575  candidate_cols=2617
  CLOBBER = 0        (no F3 column dropped or type-changed)
  ADDITIVE = production_orders.id_label, users.operator_pw_hash,
             + all columns of labels/sample_boxes/scanned_boxes/
               idempotency_keys/mirror_replay_dlq                    → PASS
```

Structural spot-checks on the post-knex DB:

| Property | Result |
|----------|--------|
| `equipment_values` still a **hypertable**, PK `(id_equipment, ts_value)` | ✅ (not rebuilt as the F1 serial table) |
| hypertables / continuous aggregates | 4 / 14 — unchanged from F3 |
| `enterprises` primary key | ✅ intact |
| `update_prev` trigger / `piot_trig_*` fn | ✅ absent (F3-faithful) |
| `shadow_go_port` schema | ✅ absent (no comparator in single-flow prod) |
| `production_orders.id_label` → `labels` FK | ✅ created |

### Why the md5 parity gate alone is insufficient here

`scripts/prod-f3-schema-parity-check.sh` fingerprints each table as an md5 of its
column list, so it cannot distinguish an **added** column (benign) from a
**dropped/changed** one (a real F1 rebuild) — both change the hash. Post-knex it
reports `production_orders` and `users` as `F3_MISSING` purely because they gained
`id_label` / `operator_pw_hash`. That is a false alarm, not a regression. The new
`prod-knex-f3-reconcile-check.sh` compares at **column granularity** and asserts
the load-bearing property directly: **every F3 (table, column, type) still exists
unchanged** (`CLOBBER=0`); additive edge-api columns pass.

Run order at deploy (before any client data):
1. after `db-schema-f3`: `prod-f3-schema-parity-check.sh` → `F3_MISSING=0`.
2. after `db-migrate`:   `prod-knex-f3-reconcile-check.sh` → `CLOBBER=0`.

## What changed in the prod boot

- **NEW** `db/init-f3/knex-baseline.sql` — the fake-baseline seed (25 annotated).
- **NEW** `scripts/prod-knex-f3-reconcile-check.sh` — classification + column
  integrity gate.
- **`compose.production.yml`** — new `db-knex-baseline` one-shot between
  `db-schema-f3` and `db-migrate`; `db-migrate` now `depends_on` it and its
  W1.4-residual comment is resolved.

## Maintenance

The fake/run split is coupled to `edge-api/migrations/`. When edge-api adds a
migration, classify it: **fake** if F3 already provides/omits its object, **run**
if it is a net-new edge-api object. `prod-knex-f3-reconcile-check.sh classify`
FAILS if any migration file is unclassified — wire it into CI so a new migration
can't silently slip past this gate.

## Validated vs gated

- ✅ full boot sequence on a fresh `timescaledb:2.25.2-pg16`: baseline seeds 25,
  knex runs exactly the 16, `CLOBBER=0`, edge-api tables present, F3 structural
  invariants intact; classification complete; `docker compose config` exit 0.
- ⛔ **W1.6 prod dry-run boot** on an empty F3 DB — needs a deploy (do NOT run
  against prod).
- ⚠ carries the same **PG-version delta** caveat as W1.4 (staging F3 = pg15.17;
  prod image = pg16/2.25.2) — schema-only, does not affect this reconciliation.
