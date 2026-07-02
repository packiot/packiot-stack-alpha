
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
