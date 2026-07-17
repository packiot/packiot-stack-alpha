# Mirror events close-field parity — audit queries (task #63)

Turns the mirror's "COUNT parity PASS" into "COUNT **+ close-field** parity
PASS". COUNT parity can pass while shadow `equipment_events` rows sit
`ts_end IS NULL` (OPEN) forever or carry a stale `ts_end`/`duration`,
silently inflating F2/F3 duration + availability.

## The bug this guards against

The old close path (`FetchRecentlyClosedEvents`) re-fanned prod event closes
to F2/F3 only for prod events with `ts_event >= now()-48h` **AND**
`id_equipment_event > cursor-400_000`. On prod's ~2.45B-id space the 400k PK
bound is narrower than 48h, so any close landing outside that window was
never re-fanned → the shadow row stayed OPEN forever. Task #63 replaces it
with a **shadow-driven** close-sweep (see
`services/mirror-worker-go/internal/reconcile/events_sync.go:runEventCloseSweep`).

## Live signal (preferred)

The comparator asserts this continuously — no manual run needed:

| Metric | Meaning | Healthy |
|---|---|---|
| `mirror_worker_comparator_event_open_strands{plane="f2"\|"f3"}` | open (`ts_end IS NULL`) shadow rows older than the strand threshold, per plane | low, and **f2 == f3** |
| `mirror_worker_comparator_event_open_strands_skew` | `abs(f2 - f3)` | **0** (F2==F3) |
| `mirror_worker_reconciler_events_total{outcome="reclosed"}` | rows the sweep corrected | trends up then flattens |

`skew != 0` is a hard F2!=F3 close-field divergence — the two shadow planes
disagree on close state.

## Manual point-in-time audit

`shadow_go_port` (F2) is a schema in the staging `packiot` DB; `packiot_shadow`
(F3) is a **separate database**. Run the per-plane block in its own session,
then compare the two counts by hand — they MUST be equal (F2==F3).

### A. Open-strand count per plane — older than 48h

F2 — on the staging `packiot` DB:

```sql
SELECT count(*) AS f2_open_strands
  FROM shadow_go_port.equipment_events
 WHERE id_enterprise = 3            -- staging CPACK
   AND ts_end IS NULL
   AND ts_event < now() - interval '48 hours';
```

F3 — on the `packiot_shadow` DB:

```sql
SELECT count(*) AS f3_open_strands
  FROM public.equipment_events
 WHERE id_enterprise = 3
   AND ts_end IS NULL
   AND ts_event < now() - interval '48 hours';
```

PASS = `f2_open_strands == f3_open_strands` (F2==F3) AND both ≈ prod's own
open count (below). A one-directional excess = under-close strands the sweep
should be draining.

### B. Prod's own open count (context denominator)

On prod tsp12 (SELECT-only, `BEGIN READ ONLY`):

```sql
SELECT count(*) AS prod_open
  FROM equipment_events
 WHERE id_enterprise = 1            -- prod CPACK
   AND ts_end IS NULL
   AND ts_event < now() - interval '48 hours';
```

Shadow open strands materially ABOVE `prod_open` = the divergence class #63
fixes: shadow observed the OPEN and never saw the (out-of-window) close.

### C. The open strands themselves (triage list)

Per plane (swap schema for F3), to see which equipment/events are stranded:

```sql
SELECT id_equipment, ts_event, status, age(now(), ts_event) AS open_for
  FROM shadow_go_port.equipment_events
 WHERE id_enterprise = 3
   AND ts_end IS NULL
   AND ts_event < now() - interval '48 hours'
 ORDER BY ts_event
 LIMIT 100;
```

Cross-reference each `(id_equipment, ts_event)` against prod's authoritative
row (join by `packml_topic` — surrogate ids differ across systems; prod
topics carry the `C-PACK/` prefix, shadow the `CPACK/` remap). If prod has a
`ts_end` for it, the sweep will close it on its next pass; if prod is ALSO
open, it is a genuine live strand (correctly left visible — the sweep never
fabricates a close).

## Index note (DBA)

The open-strand scans hit `equipment_events` filtered on
`(id_enterprise) WHERE ts_end IS NULL`. A partial index makes both the sweep
candidate fetch and this audit O(open rows):

```sql
-- per shadow plane (shadow_go_port + packiot_shadow.public)
CREATE INDEX CONCURRENTLY IF NOT EXISTS equipment_events_open_strand_idx
    ON equipment_events (id_enterprise, ts_event)
 WHERE ts_end IS NULL;
```

Coordinate with the **dba** agent before creating on the staging DB.
