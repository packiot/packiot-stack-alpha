# t284 — eliminate 3 LIVE public.h_* SRF carriers (downtime + machine-speed)

Part 1 of finishing the public-schema `h_*` carrier cleanup. Converts the three
plpgsql SRFs that `RETURNS SETOF <public.h_*>` to `RETURNS TABLE(<cols>)` and drops
the now-orphaned carrier tables. Consumer-transparent: unchanged call signature and
result columns.

| Carrier table dropped | Producing function rewritten |
|---|---|
| `public.h_machine_speed` | `serving.machine_speed(int,text,text,text,text,text,timestamptz,timestamptz,text,text)` |
| `public.h_piot_get_downtimes_per_category_equipment_level_new` | `public.h_piot_get_downtimes_per_category_equipment_level_new_4(int,text,text,text,text,timestamp,timestamp,text)` |
| `public.h_downtimes_table_with_sector_2` | `public.h_piot_get_downtimes_sector_microstops(int,text,text,text,text,timestamp,timestamp,boolean,boolean)` |

`serving.downtime_by_category` (returns its own `downtime_by_category_row`, NOT an
`h_*`) is unchanged; it calls `h_piot_get_downtimes_sector_microstops` internally, so
it was re-proven identical after the helper rewrite.

## Why `#variable_conflict use_column`

All three are plpgsql. `RETURNS TABLE(...)` declares the result columns as OUT-param
**variables**; several share names with source columns (`id_equipment`,
`id_enterprise`, ...). plpgsql's default `variable_conflict = error` then aborts the
call (proven: `column reference "id_equipment" is ambiguous`). Adding
`#variable_conflict use_column` as the body's first line forces column precedence —
restoring the exact resolution the original `RETURNS SETOF <composite>` had (it
declared no OUT variables, so columns always won). Bodies are otherwise verbatim.

## HARDPROOF (byte-identical, ent 3 = CPACK)

Each rewrite was validated in a `REPEATABLE READ` transaction (same snapshot + same
`now()` for before & after), comparing full row-text (`(t.*)::text`) via symmetric
`EXCEPT ALL`. **symdiff = 0** for every case:

| function | window | rows | symdiff |
|---|---|---|---|
| `serving.machine_speed` | 7d DAY | 20 | 0 |
| `serving.machine_speed` | 2d HOUR | 15 | 0 |
| `h_piot_get_downtimes_per_category_equipment_level_new_4` | 30d | 1 | 0 |
| `h_piot_get_downtimes_sector_microstops` | 30d | 5421 | 0 |
| `serving.downtime_by_category` (calls helper) | 30d | 1 | 0 |

Post-apply live checks (read-api `:9104`, `X-Api-Key: stg-cpack-key`):
- `POST /v1/query {"dataset":"machine-speed"}` → 200 + series
- `POST /v1/query {"dataset":"downtimes-per-category"}` → 200 + categories (MAN-01, PRG-15)

Superset "Machine Speed" / "Downtime Analysis" dashboards are backed by `bi.equipment_speed`
/ `bi.downtimes` (independent views) — no Superset dataset references these SRFs; unaffected.

## Apply order (staging, packiot_analytics)

```sh
psql ... -f 01-rewrite-fns.sql   # DROP+CREATE the 3 fns (RETURNS TABLE + pragma)
psql ... -f 02-drop-carriers.sql # DROP the 3 orphaned carrier tables
```

`rollback.sql` restores the 3 tables + the original `RETURNS SETOF` definitions.
