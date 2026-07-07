# ADR-0016 §6 — THE FLIP RUNBOOK (prepared 2026-07-06)

The consolidation flip, ready to execute the moment the gates read
green. Every step is an env/DDL change; total execution ≈ 30 minutes;
rollback is env-reversal (old DB frozen-read for 30 days).

## Gate checklist (all must be true before step 1)

- [ ] Full-surface comparator (10 fidelity surfaces + 3 identity
      fingerprints, `/d/bake-flow-parity`) green for 7 consecutive
      days — clock RESTARTED 2026-07-07 (envelope-routing repairs;
      see 06-state §5) → ~2026-07-14. Trust 06-state for the live date.
- [x] Shift-resolver close-out — DONE EARLY 2026-07-06 (same-row
      evidence 0/46; trigger dropped on staging, Go fill live on all
      flows, verified 07-07; roadmap A1).
- [x] PowerBI 37+1-object gate — WAIVED-ON-EVIDENCE 2026-07-07 (no
      PowerBI access available, ever; automated shape gate PROMOTABLE +
      prod-read fidelity as basis; rendered-report acceptance deferred
      to Phase F customer-side — see gate board G3).
- [ ] sap_13 either ported+baked or explicitly deferred to the
      post-flip ledger with back4-api owner sign-off (human).
      (Port ENABLED on staging 2026-07-06, 72h bake running; #223
      closed with the back4-api read-only finding.)
- [ ] hist_* tables verified queryable on the target DB (§5 — DONE:
      EV 2.41M · POs 20.6k · runtime 20.6k · user_logs 137k).
- [x] refdata-api SQL dependencies exist on the target DB — PROVISIONED
      2026-07-07 (2 fns + 4 operator views + 2 return-type tables +
      equipment_events_low_speed; as-executed SQL:
      `migrations/0018-f3-refdata-deps.sql`; smoke: timeline 2010 rows,
      pending 14781 on F3). Discovered absent during wave-3 build —
      every /v1 operator route would have 500'd at flip.
- [ ] `uns_equipment_current_metrics` freeze has a named cause or a
      fix (2026-07-07 audit: no producer post-10.9 — the
      `sparkplug.uns_metrics` routing key is published by nothing;
      table frozen on all 3 flows; see 06-state §5 watch items).
- [ ] At R6/R7: disable the Node-RED Sparkplug tab's
      `Publish: oee (amqplib)` node, verify the per-tenant queue
      (`oeecloud-worker-q-<tenant>`) drained, and confirm its bare-key
      fallback never fired.

## Decision recorded: PROMOTE packiot_shadow (no rename)

DSN change over rename: rename risks catalog surprises under
TimescaleDB; every consumer already parameterizes DB by env. The
consolidated DB keeps the name `packiot_shadow` internally; a DNS-ish
alias (`PACKIOT_DB=packiot_shadow`) is the single knob.

## Step sequence (one deploy, ordered envs)

1. **Freeze**: announce; stop merging feature PRs.
2. **edge-transformer**: `SHADOW_EMIT_REFACTORED=false`,
   `SHADOW_EMIT_PRODUCTION=false` → single emit, source_type=""
   retargeted by the worker env below. (Alternatively: emit ""
   only.)
3. **oeecloud-worker**: route `""` → (shadowPool, public) — env
   `PRODUCTION_ROUTE_DB=shadow`. All jobs' `flows.Standard` collapses
   to ONE dest (packiot_shadow). `BAKE_COMPARATOR_ENABLED=false`
   (nothing left to compare).
4. **edge-api**: `DB_HOST/DB_NAME` → packiot_shadow. user_logs home
   moves with it (§5 decision: edge-api writes the consolidated DB
   directly — audit atomic with writes).
5. **mirror-worker**: target DB → packiot_shadow (prod mirror
   continues feeding the ONE flow); value-sync/fanout collapse to
   single-write (`VALUE_FANOUT=false`).
6. **query-api**: DSN → packiot_shadow.
7. **operator UI**: no change (talks to edge-api).

## Retirement list (separate PRs, same day)

| # | Retire | Mechanism |
|---|--------|-----------|
| R1 | shadow-mirror service | compose removal (user_logs now written on the flow) |
| R2 | dual-emit flags + SHADOW_* envs | env cleanup PR |
| R3 | fan-out in mirror-worker | code path removal (plain write) |
| R4 | shadow_go_port schema | `DROP SCHEMA ... CASCADE` after 30-day freeze |
| R5 | hasura + hasura-init containers | compose removal (front4 §225 recheck first) |
| R6 | edge-nodered GraphQL tab + sim flows | flow-manager edit (cosmetic; ingest already MQTT) |
| R7 | oeecloud-node-red pair | container removal (10.x complete) |
| R8 | piot_* engine on old F1 | stays frozen with the old DB; dropped with R4's freeze expiry |
| R9 | F2 dashboards/panels | grafana cleanup |

## Rollback

Envs reversed in one deploy; old packiot DB untouched (frozen-read).
The 30-day freeze window is the undo horizon. After expiry: EBS
snapshot before final drop.

## Post-flip verification (first hour)

1. plc-sim rows land in packiot_shadow.public only (25/10min cadence).
2. Operator action → user_log (edge-api) → PO + window on the flow.
3. Runtime engine ticks clean (`jobs_ticks_total{outcome="ok"}`).
4. UNS current-hour updates; /d/ dashboards read the consolidated DB.
5. hist_* queries return (the past survived).
