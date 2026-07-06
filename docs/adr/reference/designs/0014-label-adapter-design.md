# Label-adapter design — one boxes pipeline, N enterprises (2026-07-03)

## The problem (user-raised)

Two label formats exist today (`Label_Neopac` delivery labels,
generic `Label` counter labels) and the first port gave each its own
code path (boxes13.go + per-customer CAggs) — the exact per-customer
sprawl disease of the legacy `piot_*`/`*_cust_NN` namespace, reborn
in Go. Every future enterprise with a scanner would add another file.

## The pattern: normalize at the shredder, configure per tenant

- **Raw stays raw**: `equipment_values.analogs` keeps the vendor
  payload verbatim (prod parity; prod views/functions read it).
- **One canonical pool table**: `customer_reports.boxes`
  (customer_id, label_key, ts_value, id_order, id_equipment, id_area,
  id_site, net_production, qty), UNIQUE (customer_id, label_key,
  ts_value, id_order) — the ADR-0012 pool pattern applied to the
  beep chain.
- **Per-tenant DESCRIPTORS, not code**: reference table
  `label_formats` (public, CS-Admin-manageable later). One row per
  (enterprise, label_key) choosing an ARCHETYPE + field mapping:

| archetype | semantics | today's instance |
|---|---|---|
| `delivery` | label carries its own date+ISO-duration time (+tz) and workcenter; each label = one box row upserted by (ts, order) | Label_Neopac |
| `counter` | label rides the producing equipment's row; time-bucket sum(value)/count by job | Label |

- **Fully parameterized SQL**: field names travel as text parameters
  into jsonb operators (`analogs -> $1 ->> $2`), timezone as a
  parameter — descriptors cannot inject SQL.
- **Legacy surfaces become façades**: `equipment_boxes_cust_13` →
  view over the pool (customer_id=13, label_key='Label_Neopac') —
  Wave-2+3 in one move for boxes. The c13 CAggs stay as prod-parity
  legacy surface until their consumer views re-point at promotion.

## What onboarding enterprise N with a scanner costs after this

One INSERT into label_formats. Zero code.
