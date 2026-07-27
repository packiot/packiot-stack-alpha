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
must NOT be built by concatenating fragments.** The authoritative method is a
curated schema-only dump of live `packiot_shadow` (matches by construction).

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

- ✅ target manifest (live, SELECT-only); gate FAILs empty DB (562) + fragment
  assembly (344); `docker compose config` exit 0; fragment divergence measured.
- ⛔ **Populate `snapshot/`** via `capture-f3-snapshot.sh` — needs staging DB read
  + USER go (schema-only, read-only-in-effect).
- ⛔ **Reconcile edge-api knex** so it doesn't rebuild F1 over F3 (USER decision;
  options in the `compose.production.yml` `db-migrate` comment).
- ⛔ **W1.6 prod dry-run boot** on an empty F3 DB — needs the snapshot + a deploy
  (do NOT run against prod).
