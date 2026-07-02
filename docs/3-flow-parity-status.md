# 3-Flow parity status + remaining work (ADR-0012)

- **Status**: Updated 2026-07-02 (evening) — supersedes the interim morning version
- **Depends on**: ADR-0010 (Go decode), ADR-0012 (schema refactor + packiot_shadow), ADR-0013 (shadow-mirror), ADR-0014 (OEE math extraction)

## Goal

Flows 1, 2, and 3 receive **identical** data:

| Flow | Destination | Currently populated? |
|---|---|---|
| 1 | `packiot.public.*` | ✅ Fully — mirror-worker + edge-nodered simulator + oeecloud-worker default |
| 2 | `packiot.shadow_go_port.*` | ✅ equipment_values (edge-transformer dual-emit + mirror-worker fan-out) + production_orders (full lifecycle) + equipment_events_man (inserts only) |
| 3 | `packiot_shadow.public.*` | ✅ Same set as Flow 2, byte-parity on recent windows |

"Identical" means: same rows in same schemas, with same downstream
derivations (equipment_events, runtime aggregates, PO scoring).

## Where we stand (2026-07-02 evening)

### Data plane (equipment_values)

- edge-transformer dual-emits `source_type=go` + `source_type=refactored`
  for every MQTT/AMQP event → Flows 2 + 3 verified byte-identical
- **mirror-worker fan-out (PR #193)**: every prod-anchored CPACK delta
  is now written to all 3 destinations with a single Go-side timestamp,
  so `(ts_value, id_equipment)` — the parity join key — matches across
  flows. Closes the 120-vs-6 rows/15min gap the CPACK verification found
- Watch `mirror_worker_value_fanout_total{outcome!="ok"}` for drops
- Remaining volume source NOT fanned out: edge-nodered simulator
  (enterprise 1/2 traffic publishes straight to the `oee` exchange and
  lands in Flow 1 only). Acceptable while CPACK is the parity target

### Control plane (operator actions) — shadow-mirror ACTIVE

- 11 handlers live (PRs #175, #178, #179, #184, #185), covering ~95% of
  daily user_logs volume; `SHADOW_MIRROR_ENABLED=true` on staging
- **Bugs 247 + 248 fixed (PR #191)**: production_orders lifecycle now
  replays by the natural key `(id_enterprise, id_order)` resolved from
  Flow 1, and every INSERT qualifies its `ON CONFLICT` target. Flows
  2 + 3 verified identical (same POs, same statuses, stops flipping
  status=3 in both)
- Zero-row UPDATEs are now observable:
  `shadow_mirror_update_noop_total{schema,table}`
- **Known gap**: `equipment_events_man` edits (manual-event-edited,
  event-splitted boundary updates) still target Flow 1's
  `id_equipment_event`, which never matches shadow rows. No natural key
  exists — `(id_equipment, ts_event)` is not unique. Needs an id-map
  (INSERT ... RETURNING captured at create time, mirror_id_map-style).
  The noop counter measures the gap until then

### Derived data (equipment_events, runtime aggregates) — trigger-derived

- Still Flow 1-only: `piot_set_shift_before_insert` trigger + ~20
  `piot_*` PL/pgSQL functions + pg_cron rollups exist only on
  `packiot.public`
- ADR-0014 moves this compute into oeecloud-worker (Go); Flows 2 + 3
  get derived data when that lands — deliberately NOT by copying the
  triggers (that would duplicate the thing we're retiring)

## Concrete remaining work

1. **equipment_events_man id-map** — design + implement (see Known gap
   above); truth-reset shadow events tables when it lands
2. **`/d/3-flow-parity` Grafana dashboard** — per-flow row counts +
   divergence, PO status parity, fan-out + noop counters. Meaningful now
   that fan-out ships
3. **ADR-0014 Phase 2** — port `piot_set_shift_before_insert` to Go
   (oeecloud-worker resolver; 168h comparator bake; then retire trigger)
4. **ADR-0014 Phase 3+** — port remaining PL/pgSQL to Go / TimescaleDB
   CAggs (piot_create_equipment_runtime_* → CAggs, area rollups → Go,
   piot4_13_* per-customer handlers)
5. **ADR-0012 Phase 4** — real-staging migration (remaining 33 façades,
   customer_dashboards pool promotion) gated by the PowerBI 37-object
   compat test plan; then prod
6. **Simulator fan-out — DEFERRED (explicit decision 2026-07-02)**:
   CPACK is the parity target; enterprise 1/2 simulator traffic stays
   Flow 1-only. Revisit only if parity scope widens. Known consequence:
   simulator PO churn interacting with the mirror reconciler can
   strand shadow running-POs after a truth-reset (observed post-#191:
   3 simulator equipments wedged the running-PO index, 31 loud 23505
   failures, CPACK unaffected). One-time fix = the **truth-nudge**:
   `UPDATE shadow SET status = f1.status ... WHERE shadow.status = 2
   AND f1.status <> 2` joined by natural key. Candidate future
   improvement: a periodic reconcile pass in shadow-mirror doing
   exactly this (mirrors mirror-worker's EnsureActivePOs pattern)

## Acceptance criteria for "100% parity"

- [x] Flows 2 + 3 byte-identical for edge-transformer-routed
      equipment_values (verified 2026-07-01)
- [x] production_orders identical across shadow flows with full
      lifecycle (created → running → finished) — verified 2026-07-02
      post PR #191
- [ ] All 3 destinations have identical `equipment_values` rows within a
      60-second window (measured by comparator like ADR-0008) — fan-out
      shipped, verification window open
- [ ] equipment_events_man identical after the id-map lands
- [ ] All 3 destinations have identical `equipment_events` (once
      derivation moves to Go per ADR-0014)
- [ ] Grafana dashboard `/d/3-flow-parity` shows continuous
      0-divergence for 7 days

## History

- 2026-07-02 (morning): interim status — shadow-mirror idle, target
  tables missing, derived-data blockers identified
- 2026-07-02 (midday): shadow-mirror enabled + tables added (#184),
  order-changed handler (#185), prod-shape bugs 243-246 fixed
  (#186, #188, #189)
- 2026-07-02 (evening): bugs 247 + 248 found via live verification and
  fixed (#191 — natural-key replays + qualified ON CONFLICT);
  mirror-worker value fan-out (#193); MQTT-idle health hygiene (#192)


## Flow 3 → 100% prod-parity roadmap (status 2026-07-02 late)

DONE this session: hypertable + 9 CAggs · pools + façades · reference
data synced from Flow 1 (enterprises/sites/areas/equipments/shifts/
shift_hours/packml_register/teams/downtime_reasons/language_packs —
users/products are empty AT SOURCE, arrive from prod at Phase 5) ·
zero PL/pgSQL · zero Hasura · refdata-api flow-routing now UNBLOCKED.

REMAINING to 100%:
1. equipment_events derivation → Go (ADR-0014 P3: port
   piot_review_equipment_events + state_lines_..._mirror_reason3 +
   split/insert/delete-line-downtime; schema-parameterized like the
   shift resolver so F2+F3 get it together) — THE next arc
2. runtime rollup tables (equipment/area/site_runtime_*) → CAggs/Go
   (same ADR phase; F3 CAgg base is ready)
3. remaining 33 PowerBI façades (Waves 1-3; 37-object gate)
4. Wave 2 ports #2/#3 (shift_06, sap_13+back4-api) — speed_33 pattern
   proven with 63/68 exact prod fidelity (5 deltas = rolling-window
   artifact, explained in commit)
5. prod-sourced users/products + real-data bakes (Phase 5 access path)
6. ADR-0010 cutover (kills the dual-emit residual; needs simulator
   MQTT rerouting — separate arc)
Calendar: shift bake close-out 07-09 (ready-SQL committed) · Hasura
window 08-01 · prod Hasura Cloud console logging = user action.
