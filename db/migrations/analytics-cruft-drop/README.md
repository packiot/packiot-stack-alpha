# analytics-cruft-drop — retire dead Hasura-era serving functions

**Status:** APPLIED on staging `packiot_analytics` (`i-064bb36d1c454d861`) 2026-09-04.
Production untouched. **Reversible** (see below).

## What was dropped

**56 dead PL/pgSQL functions** (the Hasura-era serving fossils). `h_piot_*`
went from **88 → 39**. Full list: [`dropped_function_names.txt`](./dropped_function_names.txt).
DROP statements (signature-qualified): [`01_drop_dead_functions.sql`](./01_drop_dead_functions.sql).

## Why — triple-signal ref-proof (never guess-drop; the ADR-0036 discipline)

The redesign (analytics-v2 §5.1) established the mature architecture is already
live: **OEE compute → Go stream-engine**, **serving → Go read-api/refdata + `bi.*`
views**. The `h_piot_*` functions are the Hasura layer that architecture replaced.
Each dropped function was confirmed dead on **all three** independent signals:

1. **Call stats** — `pg_stat_user_functions.calls = 0` (stats never reset; the
   live helpers show millions of calls in the same window, so tracking works).
2. **In-DB references** — `0` other functions/views reference it (so dropping
   cannot break any surviving function — verified by the candidate filter).
3. **Code references** — `0` LIVE references across **all** backends that call
   the DB (read-api, stream-engine, back4-api, edge-api), verified by three
   independent ref-check agents + a direct grep, reconciled by KEEP-union
   (keep if *any* signal says live).

**Why 0-calls alone was NOT enough** (the trap this process caught): read-api's
`datasets.go` dataset registry live-calls ~34 of the candidates
(`h_piot_overview_*`, `h_piot_get_downtimes_*`, `h_piot_home_uns`, …) via
`SELECT * FROM fn()` / the `perEquipment` helper — they show 0 staging calls
only because those dataset paths had no traffic on staging. Those **34 were kept**.
Likewise `h_piot_set_production_target`/`_scrap_target` (edge-api write path) and
the 15 `piot_create_*_runtime_*` provisioning procs (stream-engine `provision.go`)
and the `get_*_sync` fns (back4-api) — **all kept** (51 total).

The 56 dropped have callers **only** in `edge-node-red/db/19-hasura-full-parity.sql`
and `20-oee-engine-parity.sql` — the **separate edge database**, out of the
staging analytics blast radius.

## Reversibility (3 independent sources)

1. **Canonical (checked-in):** every dropped function's `CREATE OR REPLACE`
   definition lives in `edge-node-red/db/19-hasura-full-parity.sql` and
   `20-oee-engine-parity.sql`. Re-run those (filtered to the dropped names) to
   restore.
2. **Exact staging snapshot:** the full restore script (all 56 `pg_get_functiondef`
   outputs, captured *before* the drop) is on the box at
   `/tmp/analytics_dropped_functions_restore.sql`.
3. **Regenerable:** `git revert` this commit is a no-op (the drop is DB-side);
   to restore, apply source (1).

## Scope note

This is the **function** slice of the cruft cleanup (#182 / necessity matrix
#179). The `h_*` return-type scaffolding *tables* and other cruft tables are a
separate ref-checked pass (still #182). The 39 surviving `h_piot_*` are the ones
read-api/edge-api actively call — a candidate for a later port-to-Go pass, but
NOT dead.
