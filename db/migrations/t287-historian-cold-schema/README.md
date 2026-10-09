# t287 — historian gateway `cold` schema (symmetric with `live`)

Deferred **R10** of the t282 gateway sweep ("same for the historian"), now approved.

## What

On the **hist-gateway** Postgres instance (`docker exec hist-gateway`, db `postgres`),
give the historian COLD-store + hot∪cold union + boundary objects their own **`cold`**
schema, symmetric with the hot **`live`** FDW schema. Before t287 they sat in `public`
alongside the pg_duckdb / postgres_fdw extension objects.

Moved `public` → `cold` (8 objects):

| kind  | objects |
|-------|---------|
| views | `hist`, `hist_ee` (cold read_parquet sources), `ev_all`, `ev_all_events` (hot∪cold unions) |
| tables| `hist_cutover`, `ev_events_cutover` (disjointness boundaries), `hist_promoted_enterprise` (R1 allow-list), `hist_meta` (R5 append stamp) |

**Untouched:** `live` (FDW foreign tables — the hot side, referenced qualified), and
all pg_duckdb / postgres_fdw **extension** objects (`read_parquet`, `duckdb.*`, the
DuckDB aggregates) which STAY in `public`.

## Why it's non-destructive

`ALTER … SET SCHEMA` is a pure catalog reparent — no data copy, PKs preserved.
Inter-view dependencies are stored by **OID**, not by name, so `ev_all` keeps resolving
its now-`cold` sources (`hist`, `hist_cutover`, `hist_promoted_enterprise`) with **no
view recreate** and independent of order.

## Consumer resolution

- **Gateway-internal, unqualified-name scripts** (`refresh-hist-cutover.sql`,
  `refresh-ee-cutover.sql`, `stamp-hist-meta.sql`, the staleness/coverage monitors)
  resolve via a DB-level `search_path = cold, public` (single-purpose gateway DB; `public`
  stays for `read_parquet`). No script edits needed.
- **External consumers** are repointed to the explicit qualification (independent of the
  GUC): read-api `services/read-api/cmd/refdata-api/historian.go` → `cold.ev_all` /
  `cold.ev_all_events`; Superset `configs/superset/assets/datasets/historian_union/ev_all.yaml`
  → `schema: cold` + `FROM cold.ev_all`.
- **Fresh-boot parity**: `services/historian-gateway/docker-entrypoint-initdb.d/10-historian-gateway.sh`
  creates the objects in `cold` (via `search_path = cold, public`), sets the DB default
  search_path, and grants `cold` to the read-only `cloudbeaver_histro` browser role.

## Apply / rollback

```sh
# apply (on the app box that has `docker exec hist-gateway`)
docker exec -i hist-gateway psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < 01-cold-schema.sql
# rollback (moves everything back to public, RESETs search_path, drops empty cold)
docker exec -i hist-gateway psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f - < rollback-01-cold-schema.sql
```

## Hardproof (staging, 2026-09-14)

- `ev_all` ent3 fixed past window `[2026-08-01,2026-09-13)` — **7,225,595** rows,
  gross 138001274.380 / net 138052268.380 — **UNCHANGED** vs pre-move, via BOTH the
  search_path belt (bare `ev_all`) and `cold.ev_all`.
- `ev_all_events` ent3 same window — **61,731** / dur 179714708 — UNCHANGED.
- R1 leak probe (non-promoted ent6, 2024-01) — **0 / 0** (isolation intact).
- `historian-integrity-monitor.sh` — cutover-coverage (R1) PASS, staleness (R4/R5)
  PASS, ee-coverage (R7) pre-existing SOFT warn; **exit 0**.
- Append post-run hooks (`stamp-hist-meta.sql`, `refresh-ee-cutover.sql`) resolve the
  moved objects and run clean.

Prod: **not applied** (staging only).
