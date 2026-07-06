# Production vs the new stack — every deliberate difference

> Audience: engineers, reviewers, auditors. The contract of this
> migration is 100% behavioral parity at consumer surfaces — so every
> place where the new stack deliberately differs from the client-side
> production system is listed HERE, with its justification. If a
> difference isn't on this page (or the ADR-0016 bloat ledger), it's
> a bug.
>
> Status date: 2026-07-06.

## 1. Mechanism swaps (same math, different machinery)

| Prod mechanism | New mechanism | Equivalence argument |
|---|---|---|
| Hand-rolled 1-minute aggregate table (`agg_equipment_values_1min_t`) fed by a trigger + 7.6KB feeder fn + invalidation-log + 12KB recalc-search | **Native TimescaleDB hierarchical CAggs** (`ca_agg_1min` → `ca_agg_1hour`) | Identical grouping dimensions (incl. `state`, `ts_value_production`, `duration = count·60`, avg-of-avgs weighting). The prod subsystem was a workaround for a Timescale version that predated CAgg-on-CAgg; ~20KB of PL/pgSQL is *obsoleted*, not ported |
| pg_cron dispatcher (`piot_proc_refresh_*`) with per-step EXCEPTION blocks | Go jobs runner (per-tick timeout, panic recovery, Prom outcomes, boot-tick + stagger, advisory locks) | Same pass order and fail-soft semantics; strictly better observability |
| PL/pgSQL trigger `piot_set_shift_before_insert` labels rows on insert | Go **shift resolver** (cached calendar, same tie-break rules) labels on write, ALL routes | Closed out on **same-row evidence: 0/46 mismatches** vs the trigger on identical rows. Trigger dropped on staging 2026-07-06 |
| Node-RED wrap → AMQP ingestion | **MQTT/Sparkplug B → edge-transformer** (10.9) | Same decoded metrics; cross-library decode parity was verified against the exact Node lib prod wraps; adds durability guarantees prod lacks |

## 2. Preserved prod bugs ("amber bugs" — kept deliberately)

Behavior parity means bug parity until consumers sign off on a fix.
These are pinned by failing tests so nobody "fixes" them silently:

| # | The bug (in prod for years) | Where pinned |
|---|---|---|
| 1 | The WEEK roll-up writes its `oee_p` update to the **1MONTH** table (copy-paste) | `rollup/grains.go` + `TestGrainMatrix` |
| 2 | The UNS jobs refresher sets `production_ordered := production_programmed` | `uns/current_rest.go` (documented in-line) |

Fix path: the ADR-0016 **bloat ledger** — consumer-signed-off changes
after the flip, never port side effects.

## 3. Intent-restored divergences (prod behavior was an accident)

| Prod accident | New behavior | Bound |
|---|---|---|
| Day tail references the LOOP VARIABLE after the loop (last row's day-anchor applied to all rows; errors if loop empty) — in the **dead** day generation | Per-row anchors | The accident died with the dead generation; live `production2` has the formula commented out (not ported) |
| Entity shift tails leak the loop variable the same way | Per-row (`e.id_area` / `e.id_site`) | Identical when all equipments share a site/tz (the CPACK case); strictly defined otherwise |
| `ORDER BY`-dependent nondeterminism in a translator (`active DESC NULLS LAST LIMIT 1` ties) | Deterministic tie-breaks | Documented in mirror-worker history (PR #83) |

## 4. Configuration instead of hardcoded tenants

Prod bodies hardcode enterprise/area lists **that differ per
function** (day excludes CPACK=35; shift does not; hour's list ends
117, day's ends 118…). The ports preserve each body's list as the
*default config* and expose:

- `PO_RECALC_EXCLUDED_ENTERPRISES` (prod: `6`)
- events/rollup excluded areas + enterprises (per family)
- `ROLLUP_MACHINE_LEVEL_ENTERPRISES` (prod: `6` — client-6 machines
  join the shift grain)

**Deliberate staging divergence**: our flows keep CPACK in the
day/hour grains (prod excludes it) because CPACK is the staging
test tenant. The parity harness inlines *prod's* lists when comparing.

## 5. Dead legacy code — verified dead, not ported

Call-site verification (the dispatcher's `perform()` lines) proved
these never run in prod; they were **not** ported:

- `piot_get_equipment_runtime_1day_production` (9KB — superseded by
  `production2`; its guard cannot fire against prod's own data)
- `piot_uns_equipment_refresh_current_{day,shift}` (commented out in
  `piot_refresh_uns`)
- `piot_uns_equipment_refresh_current_jobs` (7.6KB — the live one is
  `_without_equipment_value`)
- plain `get_report_shift_enterprsie_06` and `06b` (the live chain is
  `06c`)
- The entire `1min_t` feeder subsystem (see §1)

Beware: prod's own monitoring (`piot_monitor_function`) logs the OLD
names in two of these cases — telemetry lies, call sites don't.

## 6. Things the new stack has that prod doesn't

- Durability guarantees (ADR-0011): publisher confirms, outbox,
  persistence, sanity clamps on convergence syncs, `/healthz` with
  degraded reasons.
- Continuous self-verification (bake + identity fingerprints).
- Test coverage: unit + guard tests + golden fixtures + the
  differential harness.
- Config-driven tenancy (§4) and the customer_reports pool +
  descriptor tables (label_formats etc.) replacing per-tenant code.
- `hist_*` tables: the pre-migration history preserved queryable.

## 7. Known-transitional states (expire on their own)

Tracked live on `/d/bake-flow-parity`; every non-zero must carry a
named cause + expiry. As of 2026-07-06: pre-cutover-era rows rolling
out of comparison windows (~07-08), current-week surface resets at the
week roll (07-07), F3 fingerprints converge as its (recently enabled)
history accumulates (~07-09).
