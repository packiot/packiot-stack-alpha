# t285 — eliminate the last 2 public.h_* SRF carriers (shift-hours + day-week-begin)

Part 2 (with t284) of finishing the public-schema `h_*` cleanup — reaches **zero
`public.h_*` tables**. Converts the three `LANGUAGE sql` SRFs from
`RETURNS SETOF <public.h_*>` to `RETURNS TABLE(<cols>)` and drops both carriers.

| Carrier table dropped | Producing function(s) rewritten |
|---|---|
| `public.h_piot_day_week_begin` | `piot_get_day_week_begin_by_packml_topic(varchar)` |
| `public.h_shift_hours_per_equipment_packml_topic` | `piot_get_shift_hours_by_packml_topic_2(varchar)` · `piot_get_shift_hours_by_enterprise_packml_topic_2(varchar,integer)` |

## Premise correction — these were NOT dead

The cleanup epic classified these carriers "dead" (Hasura retired, no caller).
Re-derivation from **live** overturned that: read-api (`cmd/refdata-api/main.go`)
serves three fixed routes over them, so they are LIVE consumers of the sole
new-stack API:

| route | SQL |
|---|---|
| `/v1/shift-hours` | `SELECT * FROM piot_get_shift_hours_by_packml_topic_2($2) WHERE id_enterprise=$1` |
| `/v1/shift-hours-by-enterprise` | `SELECT * FROM piot_get_shift_hours_by_enterprise_packml_topic_2($2) WHERE id_enterprise=$1` |
| `/v1/day-week-begin` | `SELECT * FROM piot_get_day_week_begin_by_packml_topic($2) WHERE id_enterprise=$1` |

`/v1/day-week-begin` returns real rows (HTTP 200). So instead of DROPPING (which
would 500 those routes), we apply the same consumer-transparent RETURNS TABLE
conversion as t284. (The only other references are edge-node-red's retired Hasura
flows + its onprem-edge companion-DB setup SQL — a separate database, untouched.)

No `#variable_conflict` pragma needed: these are `LANGUAGE sql` single-SELECT bodies,
so RETURNS TABLE merely relabels the output columns — no plpgsql OUT-variable
shadowing. Recreate order: base before the enterprise wrapper (its body calls base).

## HARDPROOF (byte-identical)

`REPEATABLE READ` before/after row-text compare (symmetric `EXCEPT ALL`), then
live read-api re-check. Shift-hours returns 0 rows on staging (no shift-hours
configured for any tenant); day-week-begin exercises a real row.

| function | rows | symdiff |
|---|---|---|
| `piot_get_day_week_begin_by_packml_topic` | 1 | 0 |
| `piot_get_shift_hours_by_packml_topic_2` | 0 | 0 |
| `piot_get_shift_hours_by_enterprise_packml_topic_2` | 0 | 0 |

Post-apply: `/v1/shift-hours` → 200 `[]`, `/v1/day-week-begin` → 200
`[{"day_begin":-3000,"id_enterprise":3,...}]` (identical to pre-change),
`/v1/shift-hours-by-enterprise` → 200 `[]`. `public.h_*` count after t284+t285 = **0**.

## Apply order (staging, packiot_analytics)

```sh
psql ... -f 01-rewrite-fns.sql
psql ... -f 02-drop-carriers.sql
```

`rollback.sql` restores both tables + the original `RETURNS SETOF` definitions.
