# production_orders + production_orders_runtime — guardrail audit (2026-07-03)

User directive: these two tables are THE essential PO-action state;
extra care on any change. This audit is the baseline.

## Prod guardrails (READ ONLY census — the complete set)

production_orders:
- PK (id_production_order)
- UNIQUE (id_enterprise, id_order)           ← natural key (replay anchor)
- UNIQUE (id_equipment) WHERE status = 2     ← PARTIAL: one running PO per
  equipment. THE constraint the 30800 juggle dodges. Invisible in
  pg_constraint (bug-247 class) — always audit pg_indexes.
- CHECK speed (NULL or > 0)
- CHECK ts sanity: (ts_start<ts_end AND status IN (3,4)) OR (status=1
  AND ts_start IS NULL) OR (status=1 AND ts_end IS NULL) OR (status=2
  AND ts_start IS NOT NULL)
- idx: (id_equipment, ts_start, status), (id_enterprise), (status)

production_orders_runtime:
- PK (id_production_order_runtime)
- EXCLUDE USING gist (id_equipment WITH =, runtime_timerange WITH &&)
  ← anti-overlap: WHY the start block closes the open range BEFORE
  inserting the new one (statement order is load-bearing). Needs
  btree_gist.
- idx: gist (id_equipment, runtime_timerange), (id_production_order)

## Staging state after this audit

- F1 + F2: were already fully guarded (initial audit said otherwise —
  a shell-quoting bug fired the fallback echo; corrected). F2's
  partial-unique lives under the name production_orders_id_equipment_idx.
  NOTE: slice-1's juggle verification therefore ran WITH the partial
  unique enforcing — stronger than intended.
- F3: was missing BOTH CHECKs and the runtime EXCLUDE → all added and
  VALIDATED against existing rows (clean). btree_gist extension
  created on packiot_shadow.
- Learned: LIKE ... INCLUDING ALL/INDEXES DOES copy EXCLUDE
  constraints (a misremembered rule caused a redundant duplicate on
  F2 — dropped).
- Bloat note: F1 carries a duplicate natural-key unique
  (production_orders_id_enterprise_id_order_unique AND
  production_orders_un) — contract-wave candidate, verify which is
  constraint-backed before dropping.

## Rules for future pocontrol slices

1. Any new statement touching these tables must state which guardrail
   it relies on or dodges (the juggle documents the pattern).
2. Schema changes to either table: audit pg_indexes AND pg_constraint
   on all environments first (this file is the template).
3. Data verification after each slice: zero open ranges per finished
   PO, zero >1-running per equipment, EXCLUDE holds.
