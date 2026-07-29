# Production F3 schema-as-`public` assembly — ROADMAP W1.4

**Status:** BUILD + PROVE (design + gate + local validation). **Not applied to
prod. Not merged. Staging/prod SELECT-only.**
**Date:** 2026-07-27 · **Anchors:** [production-buildout-roadmap](./production-buildout-roadmap.md)
§3.1/§W1.4/R3 · [ADR-0032](../0032-collapse-to-single-flow-f3.md) (F3) ·
[compose.production.yml W1 PR #627](./production-recut-runbook.md).

This is the correctness gate for prod OEE. Full working detail + the ordered
source list live in [`db/init-f3/README.md`](../../../db/init-f3/README.md); this
file is the discoverable W1.4 record.

## The requirement

Greenfield prod runs ONE database whose `public` schema **is** F3 — the schema
staging's `packiot_shadow` carries, born directly (no F1/F2, no ADR-0032
collapse). Get it wrong → the compute chain produces **silently wrong OEE** (no
error, wrong numbers). Roadmap R3, the highest-severity build risk.

## What was found (correcting the roadmap's §3.1 premise)

The roadmap said F3 is "assembled from `edge-node-red/db/*.sql` + the
oeecloud-worker rollup DDL." Verified against code + live `packiot_shadow`, that
is **incomplete and partly wrong**:

1. **`edge-node-red/db/00-schema.sql` is a non-runnable introspection dump** (4799
   `TABLE: name | col type` report lines, 0 executable CREATEs) — a reference
   artifact, not base DDL.
2. **The real continuous-aggregate layer is not in `edge-node-red/db`.**
   `22-agg-views.sql` builds `agg_*`/`ca_*` as plain real-time **views**; live F3
   has **real TimescaleDB continuous aggregates** on a hypertable
   `equipment_values`, sourced from `migrations/0012-f3-cagg-layer.sql`.
3. **The oeecloud-worker owns no DDL.** `internal/rollup/provision.go` injects
   `search_path` and calls pre-existing `piot_create_*_runtime` functions to
   POPULATE rollup rows; the tables/functions come from the SQL files. For F3 the
   injected schema is literally `public`.
4. **No clean canonical base-hierarchy DDL file exists** (legacy: edge-api knex
   F1; dev `db/init/00-schema.sql` omits `agg_*`/`_quality`).
5. **F3-critical fixup:** `db/init/02-refactored-rollup-bigint-widen.sql`
   (int4→bigint on week/month aggregates; int4 SUM overflow denies the whole
   rollup UPDATE → stale OEE).
6. The `packiot-shadow-rename-map` audit is a **proposal, NOT applied** — F3 keeps
   legacy names; applying the renames breaks the Go worker's string-literal SQL.

## The measured proof

Hand-assembling the fragments in dependency order (`db/init-f3/assemble.sh`)
against a fresh `timescaledb:2.25.2-pg16` container and gating with
`scripts/prod-f3-schema-parity-check.sh`:

```
TARGET(F3, live packiot_shadow)  T=159 V=20 F=466 C=15 H=5   total 665
CANDIDATE (fragment assembly)    T=240 V=31 F=406 C=8  H=3   total 698
F3_MISSING = 344   EXTRA = 377   → FAIL
```

Neither subset nor superset — a divergent shape. **Conclusion: greenfield prod
must NOT be built by concatenating fragments.**

## The authoritative method — PRODUCED and PROVEN to parity

A curated schema-only dump of live `packiot_shadow`, plus a timescale-aware cagg
layer (a plain pg_dump **cannot** restore TimescaleDB continuous aggregates — it
dumps them as views over `_timescaledb_internal._materialized_hypertable_NN`).
Three ordered files (`db/init-f3/snapshot/`): `00` curated dump (best-effort) +
`05` = `0012-f3-cagg-layer.sql` (agg caggs, strict) + `10` introspected
supplement (ca_* caggs + raw hypertables, strict). Full end-to-end on a fresh
`timescaledb:2.25.2-pg16`:

```
TARGET (curated canonical F3)   T=152 V=10 F=129 C=14 H=4   total 309
CANDIDATE (00+05+10 from empty)  T=152 V=10 F=129 C=14 H=4   total 309
F3_MISSING = 0   EXTRA = 0   → PASS
```

**Version finding (USER decision):** staging F3 = **pg15.17**; prod image =
**pg16 / tsdb-2.25.2**. The gate compares **user objects only** (extension-owned
excluded) because the two TimescaleDB versions expose different internal function
sets (466 vs the 129 user-relevant). The user schema matches exactly across the
gap; the version bump is a real, conscious change (README §7).

## What was built

- `scripts/prod-f3-schema-parity-check.sh` — the **gate**. SELECT-only normalized
  manifest (tables + column fingerprints, views, functions by signature, caggs,
  hypertables) of the staging F3 target vs any candidate DB; emits F3_MISSING /
  EXTRA; PASS ⇔ F3_MISSING=0. Reuses the ADR-0032 SSM read-only transport.
- `db/init-f3/MANIFEST.f3-target` — the captured F3 target manifest (665 objects).
- `db/init-f3/assemble.sh` + `README.md` — the reviewable fragment scaffold +
  the canonical ordered source list with include/exclude rationale + landmines.
- `db/init-f3/snapshot/` + `scripts/capture-f3-snapshot.sh` — the authoritative
  producer (gated schema-only `pg_dump` of `packiot_shadow`, debris-curated).
- `compose.production.yml` — new `db-schema-f3` one-shot assembles F3 as `public`
  from `snapshot/` BEFORE knex/edge-api; `db-migrate` reordered after it and
  flagged for the knex-vs-F1 reconciliation decision.

## Validated vs gated

- ✅ target manifest (live, SELECT-only); **snapshot produced** (curated dump +
  `05`/`10` timescale layer); **full assembly gates to F3_MISSING=0, EXTRA=0** on
  a fresh `timescaledb:2.25.2-pg16`; gate FAILs empty DB (562) + fragment
  assembly (344); `docker compose config` exit 0.
- ⚠ **PG version delta** pg15.17 (staging) → pg16/2.25.2 (prod image) — USER
  decision (README §7); cagg refresh/retention policies carried from staging-tuned
  `0012-f3-cagg-layer` should be re-tuned for prod (does not affect schema parity).
- ✅ **Reconcile edge-api knex** so it doesn't rebuild F1 over F3 — DONE (W1.5):
  fake-baseline via `db/init-f3/knex-baseline.sql` + `db-knex-baseline` one-shot;
  proven `CLOBBER=0` post-knex. See
  [production-knex-f3-reconciliation](./production-knex-f3-reconciliation.md).
- ⛔ **W1.6 prod dry-run boot** on an empty F3 DB — needs a deploy (do NOT run
  against prod).
