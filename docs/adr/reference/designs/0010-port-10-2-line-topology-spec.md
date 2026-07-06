# Port 10.2 spec — line-topology writes (captured from prod mega-node)

Captured 2026-07-03 from "UPSERT: equipment_values / uns_metrics /
equipment_events" (flows.json). Scope is SMALLER than the census's "10
UPDATE paths" suggested, but its INPUTS gate the implementation.

## The writes (verbatim semantics)

On metrics with `topic_proc == "Status" && topic_type == "Parameter"`
(line first/last configuration):

```sql
UPDATE packml_register SET line_unit_seq = '<unit_order>'
 WHERE packml_topic = '<topic>';
UPDATE equipment_values
   SET id_equipment_line_infeed = 0, id_equipment_line_outfeed = 0
 WHERE ts_value < '<msg ts>' AND id_equipment = <id>
   AND (id_equipment_line_infeed > 0 OR id_equipment_line_outfeed > 0);
```

plus `id_line_first/id_line_last` ride the main equipment_values upsert
as `id_equipment_line_infeed/outfeed` columns.

## Why not implemented standalone

The inputs (`id_line_first`, `id_line_last`, `unit_order`) are NOT raw
Sparkplug fields — they come from the 30700/30800-family enrichment
chain upstream of the mega-node (line-sequence resolution via
packml_register). Porting the write without the enrichment produces
dead code; porting the enrichment IS the 30700 line-order port.

**Decision: implement 10.2 WITH 10.3/30700 as one unit** (they share
the prep chain). The scrap_incr=0 reset (30800 prep node) also belongs
to that unit.

## Column parity (shipped separately, same audit)

Prod writes `faults` (any metric carrying it) + `check_number`
(raw Sparkplug ms timestamp, every row). Worker builders extended —
see the column-parity PR.
