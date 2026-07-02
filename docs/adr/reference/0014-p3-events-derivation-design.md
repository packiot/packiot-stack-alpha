# ADR-0014 P3 — events derivation port: design (groundwork complete)

- Ground truth: `0014-p3-events-deriver-prod-funcs.sql` (prod bodies,
  captured 2026-07-02, SELECT-only)
- Target: Go job in oeecloud-worker (speed33 pattern — Go owns
  scheduling/config/observability, set-based SQL stays SQL),
  schema-parameterized so F2 (shadow_go_port) + F3 (packiot_shadow)
  get it in one port.

## The algorithm (from prod's piot_review_equipment_events)

1. Source: `ca_discrete_changes_1s` — 1-second state stream CAgg.
   ⚠ NOT niche (earlier skip-classification was wrong): it is THE
   event-derivation source.
2. `gapfill(state) OVER (PARTITION BY equipment ORDER BY ts)` — custom
   LOCF aggregate: `CREATE AGGREGATE gapfill(anyelement)
   (SFUNC = gapfillinternal, STYPE = anyelement)`.
3. Transition detect: status != LAG(status), ROW_NUMBER > 10 (warmup
   skip), LEAD(ts) = ts_end, duration = epoch diff.
4. Upsert `equipment_events` ON CONFLICT (id_equipment, ts_event);
   separate correction pass DELETEs derived rows (48h window, NOT
   forced_creation_system) that no longer match the recomputed stream.
5. `update_prev` trigger (AFTER INSERT): closes the previous open
   event (ts_end = NEW.ts_event) — the Go port must do this in the
   same statement batch (no triggers in the refactored DB).

## Port prerequisites per flow (in order)

1. `equipment_events` table in F2 + F3 (prod shape; hypertable on
   ts_event; UNIQUE (id_equipment, ts_event) — the upsert key)
2. 1s discrete-changes source per flow: CAgg over the flow's own
   equipment_values (F3's is a hypertable already ✓; F2's schema
   shares packiot's — CAgg source must be the shadow_go_port
   hypertable → convert first, same recipe)
3. gapfill aggregate per DB (2 tiny functions) OR rewrite with
   gaps-and-islands (count(state) OVER as grouper) — prefer rewrite:
   zero PL/pgSQL in the refactored DB, standard SQL
4. Config extraction: the hardcoded exclusions
   (id_area != 24, enterprise NOT IN (2,30,34,36,38,99,…),
   status_type = 4, r > 10, 25h/48h windows) become worker env/config
   — these are per-customer business toggles, exactly ADR-0014 P4's
   config surface
5. Bake: same live-comparator pattern — F1's trigger+proc output vs
   Go output on (id_equipment, ts_event, status, duration)

## Sequencing note

Do this AFTER the July-9 shift-bake close-out (one live bake at a
time keeps the divergence panels unambiguous).
