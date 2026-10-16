# cagg refresh-policy provisioning fix (#206)

Closes the provisioning gap that caused the #196 incident: the rollup-critical
real-time continuous aggregates `ca_agg_equipment_values_1min` / `_1hour` were
created (in `db/init-f3/snapshot/10-f3-timescale-supplement.sql`) with **no
refresh policy**, so their materialization watermark froze and every rollup read
re-aggregated all raw `equipment_values` past it → 300s tick timeouts.

## Files

- **`01_attach_ca_agg_refresh_policies.sql`** — idempotent. Attaches
  `add_continuous_aggregate_policy` to the two rollup-critical `ca_agg_*` caggs
  where missing (`if_not_exists`), then **asserts** both own a refresh job
  (`RAISE EXCEPTION` otherwise). Surfaces any other policy-less real-time `ca_*`
  cagg as a `NOTICE` (deferred per #208 — those have `-infinity` watermarks and
  are safe as-is; attaching without an oldest-first catch-up would open a
  read-hole).

## Companion code fix

`10-f3-timescale-supplement.sql` now pairs **every** `ca_*` CREATE with an
`add_continuous_aggregate_policy(..., if_not_exists => true)`, so a fresh DB is
correct by construction (safe there: caggs are created `WITH NO DATA`, no
watermark gap to strand).

## State when authored (2026-09-07)

| Env | ca_agg_1min / _1hour policy | This migration |
|---|---|---|
| **prod** (`packiot`) | present (hotfix jobs 1010/1011) | no-op + assertion passes |
| **staging** (`packiot_analytics`) | present (all 6 ca_* have policies) | no-op + assertion passes |
| fresh DB | created by snapshot (now policy-paired) | no-op + assertion passes |

## Safety

Attaching a refresh policy to a real-time cagg whose watermark is **frozen
mid-history** while it holds data jumps the watermark forward on the first run
and turns the older un-refreshed span into a **read-hole** (the #196 mid-fix
trap). This migration is a pure no-op on prod/staging (policies already present).
If you ever apply it to a DB where a rollup-critical cagg is policy-less **and**
holds data, first catch it up oldest-first:

```sql
CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_1min',  '<gap_start>', now());
CALL refresh_continuous_aggregate('public.ca_agg_equipment_values_1hour', '<gap_start>', now());
```

then run the migration to attach the forward-going policies.
