# Analytics rename + maturity cutover — overnight report (2026-09-04)

**Scope:** staging + new-stack only · production untouched · hardproof-only ·
reversible-by-construction. Branch `feat/historian-gateway` (pushed to origin;
8 commits). DB box `i-064bb36d1c454d861` / `packiot_analytics`.

---

## 1. Executive summary

| Workstream | State | Reversible? |
|---|---|---|
| **Rename: 33 tables → meaningful names** (DB) | ✅ DONE + hardproofed | ✅ `down.sql` |
| **Rename propagation: all code consumers** | ✅ committed + tested + pushed | ✅ git |
| **DB functions repointed** (67) | ✅ DONE | ✅ generator |
| **Dead-function drop** (56, triple-signal) | ✅ DONE | ✅ restore script |
| **Historian T1** (raw enterprises landed) | ✅ verified | n/a (read) |
| **Historian T2** (Incoplast deep-remap) | ✅ verified | n/a (read) |
| **Deploy services** (#185) | ✅ DONE — green deploy, services healthy | ✅ git |
| **Drop compat shims** (#184) | ✅ DONE — 0 shims, 4-min live watch clean | ✅ down.sql |
| **Historian T3–T6 + gateway** (#172/173/176/175) | ⏸ blocked on gateway deploy | — |
| **agg_* → metrics redesign cutover** | ⏸ gated on §7 equivalence | — |

The shims kept the running services correct throughout the rollout; after all
consumers deployed on canonical names they were dropped and a 4-minute live
watch showed **zero** `42P01` errors. The drop also *caught* a dynamic-name gap
(`entity_grains.go` concatenated `sp.Name+"_runtime_1hour"`) that static repoint
+ CI + write-verify all missed — recreated shims in ~1 min, fixed, redeployed,
re-dropped clean. The rename is fully complete: 0 shims, canonical tables only.

---

## 2. Rename cutover (DONE, hardproofed)

**33 tables renamed** via expand/contract (`ALTER RENAME` + `security_invoker`
compat view at the old name):
- 17 OEE rollups: `{equipment,area,site}_runtime_*` → `*_oee_{shift,hourly,daily,weekly,monthly}`
- 16 live-state: `uns_{equipment,area,site}_current_*` → `*_live_*`

**Held (with reasons):** `production_orders_runtime` (clear name, 33 consumers);
columns (already well-named — the debt was table-level).

**Hardproof:** every table `count(new)==count(old_view)==pre`; `bi.oee_shift`
−1→2293/3→1948 unchanged; RLS preserved via `security_invoker` (SELECT isolation
+ `WITH CHECK` write-block proven); `bi.*` serving views **auto-followed** by OID
(serving layer already canonical, for free).

**Propagation (code) — committed + tested + pushed:**
- **edge-api** — production-targets, teardown, plc-status. Caught + fixed a **live
  regression the rename introduced**: `ON CONFLICT ON CONSTRAINT <pkey>` cannot
  traverse a compat view → switched to column-inference `ON CONFLICT (id_equipment,
  ts_value)`. Also: teardown's `existingTables()` probes `pg_tables` (excludes
  views) → old shim-names were silently skipped → now points at real tables.
- **stream-engine** — 40 `.go` files; `go build`+`vet`+17 test pkgs green.
- **read-api** — datasets/external + contract golden regenerated; 3 pkgs green.
- **grafana** — dashboards 18/19 (incl. `${grain}` template values remapped).

Mechanism, hardproofed and written up (`~/notes/systems/postgres-expand-contract-rename.md`):
`\b`-bounded replacement is proc-safe + constraint-safe + compound-safe
(`\bequipment_runtime_shift\b` skips `piot_create_equipment_runtime_shift`,
`equipment_runtime_shift_1week`, `equipment_runtime_1day_pkey`).

---

## 3. DB function maturity — necessity matrix + drop (DONE, reversible)

You asked whether the functions were *reviewed for maturity* or should *move to
Go*. Hardproof answer:
- The repoint was mechanical (correct for a rename — never bundle a logic rewrite).
- **The mature architecture already exists:** OEE compute → Go (stream-engine);
  serving → Go (read-api/refdata) + `bi.*`. The `h_piot_*` are the retired Hasura
  layer.
- **`h_piot_*`: 88 → 39.** Dropped **56** confirmed dead on **all three** signals
  (0 pg_stat calls · 0 in-DB refs · 0 live refs across read-api/stream-engine/
  back4-api/edge-api — 3 ref-check agents + direct grep, KEEP-union reconciled).
- **The trap avoided:** 0-calls ≠ dead. read-api's `datasets.go` live-calls ~34
  candidates (0 staging traffic on those dataset paths) → **kept**. So were the 15
  stream-engine provision procs, edge-api `h_piot_set_*`, back4 `get_*_sync` (51 kept).
- The surviving 39 `h_piot_*` are read-api-called → a candidate for a later
  **port-to-Go** pass, not dead.

Reversible: full restore snapshot on box `/tmp` + canonical defs in
`edge-node-red/db/19,20.sql`. Codified `db/migrations/analytics-cruft-drop/`.

**Plus 25 orphaned `h_*` scaffolding tables** (function-return-type composites
orphaned by the 56-function drop) — triple-confirmed dead (0 as-return-type, 0
fn/view refs, 0 rows, 0 backend code refs) and dropped reversibly (CREATE DDL
captured). `h_*` tables 64 → 39.

---

## 4. Historian (T1/T2 verified; T3–T6 blocked on gateway deploy)

- **T1** — 24 enterprise partitions landed + queryable via Athena.
  CPACK (ent 3 = 338,895,059) and Incoplast (ent 4 = 16,631,605, byte-exact to
  prior proof) confirmed; backfill count-verified every month (714/714). One
  tiny null bucket (ent 0 = 179 rows) flagged.
- **T2** — Incoplast deep-remap VERIFIED: ent 4 has exactly **4 equipment ids**
  (990015–990018, the F3 tp1 machines) at 4,054,992 / 4,613,478 / 4,057,512 /
  3,905,623 = **16,631,605** total. No tp3 line aggregates (the 33→4 remap
  dropped the lines, kept the 4 machines with F3 ids + legacy data). ✅
- **T3–T6, T2b** — the historian-gateway is **not running on staging** (DB box
  runs only `timescaledb`+`alloy-db`); the gateway `ev_all` union, Superset RLS
  on it, and front4/read-api→gateway all require the gateway deployed. Prior
  session left gateway cutover to you (operational). **Deferred with the deploy.**

---

## 5. Deferred — the one supervised step (deploy) and what it unblocks

Everything remaining is **operational deploy**, deliberately not run autonomously
overnight (harder-to-reverse live-service swaps via the historically-finicky
deploy chain, with you asleep). The shims make this safe to do deliberately:

1. **Deploy** stream-engine / read-api / edge-api to staging (code is ready +
   pushed). Hardproof each writes/reads canonical tables directly.
2. **Handle back4-api** (reads renamed tables via shim + calls `get_*_sync`) —
   update or confirm it doesn't hit analytics-staging.
3. **Drop the compat shims** (`db/migrations/analytics-rename/*.down.sql` reversed)
   once all consumers are deployed + verified.
4. **Deploy the historian-gateway** → then T3 (ev_all queryable) → T4 (Superset
   RLS) → T6 (front4/read-api → gateway).

---

## 6. Guardrails held + cost

Hardproof every step · staging + new-stack only · never prod (overrode Athena
output off the prod bucket to staging) · reversible-by-construction · triple-signal
ref-proof before any drop · secrets from env. **Cost:** no new infra; a handful of
Athena scans (columnar, 2 cols) ≈ pennies. Nothing to flag.
