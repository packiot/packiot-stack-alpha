# P3c design — UNS current-family refreshers (captured 2026-07-03)

Consumers: front4 Overview pages (GraphQL, #225) — the port is a
prerequisite for prod Hasura retirement.

## The prod family (14+ fns) is a MATRIX, not 14 programs

piot_uns_{equipment|area|site}_refresh_current_{hour|day|shift|week|month}
+ jobs variants + piot_uns_upsert_features (the row-provisioner: UNS
current tables are UPDATE-only refreshed; features/rows are created by
upsert_features).

Representative captures (0014-p3c-uns-refresher-captures.txt) confirm:
bodies differ only by (entity level, grain, source):

| axis | values | notes |
|---|---|---|
| entity | equipment / area / site | equipment reads CAggs; area+site read the RUNTIME family |
| grain | hour/day/shift/week/month (+job) | date_trunc(grain) window; end_time = begin + grain |
| source | ca_agg_equipment_values_1hour (equipment) / {area,site}_runtime_{grain} (area/site) | prod comment: 1day CAgg "muito lenta" — they bucket up from 1hour |

Equipment refreshers carry THE SAME exclusion lists as the events
deriver (id_area != 24, enterprise NOT IN (2,30,34,...)) — port shares
the deriver's EVENTS_EXCLUDED_* config (rename to a shared
EXCLUDED_AREAS/ENTERPRISES at implementation).

## Port shape (no-hardcoded-ids directive)

ONE generic refresher job + a grain/entity descriptor matrix in Go
config (static — the matrix is structural, not per-tenant; tenants are
excluded via shared config lists). Two archetypes:
- equipment-grain: aggregate flow CAgg since date_trunc(grain, now())
  → UPDATE uns_equipment_current_<grain>.
- area/site-grain: project {area,site}_runtime_<grain> → UPDATE — 
  **BLOCKED ON P3b** (runtime family port).

Row provisioning: port piot_uns_upsert_features (2.2KB, touches all 12
tables) FIRST — without it the UPDATEs no-op forever on fresh flows.

## Sequencing

1. upsert_features port (row provisioner)
2. equipment × {hour,day,shift,week,month} via generic refresher
   (CAgg sources exist on both flows — UNBLOCKED)
3. jobs variants (need PO context — partially P3b-adjacent)
4. area/site × grains — AFTER P3b rollups
5. front4 query surface (#225) points at query-api reading these

## 10.7 CLOSURE (same census round)

The only LIVE packml_register writeback in prod's flows is
line_unit_seq (ported, 10.3 slice 2); the signal_quality writeback is
commented-out dead code. **ADR-0010 = complete except 10.9** (factory
payload capture, user-gated).
