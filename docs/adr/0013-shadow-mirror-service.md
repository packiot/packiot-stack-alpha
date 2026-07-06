# ADR-0013 — Shadow-mirror service for operator-action parity across the 3-flow POC

- **Status**: Accepted — implemented (retires at the flip, R1; blessed 2026-07-06)
- **Deciders**: Emmanuel Podestá (Packiot backend)
- **Depends on**: ADR-0010 (Go decode + shadow_go_port), ADR-0011 (durability boundary), ADR-0012 (schema refactor + packiot_shadow)
- **Context repo**: `packiot-stack-alpha` (session 73)

## Context

ADR-0012 established a 3-flow validation pipeline for the schema refactor:

- **Flow 1** — `packiot.public.equipment_values` — the live staging (edge-nodered path + mirror-worker replay)
- **Flow 2** — `packiot.shadow_go_port.equipment_values` — ADR-0010 Phase 3 Go pipeline
- **Flow 3** — `packiot_shadow.public.equipment_values` — ADR-0012 refactor POC

For **data-plane events** (equipment_values, uns_metrics), oeecloud-worker's source_type routing table fans a single AMQP message into all 3 destinations (or 2 of 3, depending on which paths edge-transformer emits into).

But there's a **control-plane asymmetry**: operator actions (justify downtime, split events, start/stop POs, edit shifts) travel via HTTP → staging edge-api → direct writes to `packiot.public.production_orders` / `.downtimes` / `.equipment_events_man`. edge-api knows only about the main `packiot` DB, public schema. Nothing writes those to `shadow_go_port` or `packiot_shadow`.

Result: Flow 2 and Flow 3 have equipment_values but NO production_orders, NO downtimes, NO operator-edited events. They diverge from Flow 1 the moment an operator interacts.

## Decision

Add a new lightweight Go service `shadow-mirror` that closes the control-plane gap:

- Polls `packiot.public.user_logs` (the staging edge-api audit trail — every mutation is logged here) via a cursor pattern (mirrors the existing mirror-worker design)
- For each new operator action, decodes `category` + `payload`
- Replays the equivalent SQL against BOTH shadow paths:
  - `packiot.shadow_go_port.<table>` (via main pool)
  - `packiot_shadow.public.<table>` (via shadow pool)
- Emits Prometheus metrics + /healthz consistent with the ADR-0011 durability contract

### Why NOT the other variants

**Postgres trigger duplication (Variant B rejected)**: `AFTER INSERT/UPDATE` triggers on `packiot.public.*` writing to `shadow_go_port.*` and via `dblink` to `packiot_shadow.*`. Zero app code. Rejected because:
- Tight coupling to schemas — the whole POINT of ADR-0012 is diverging the shadow schemas from public
- `dblink` error handling is limited to plpgsql; hard to observe from Grafana/logs
- Trigger latency directly impacts the primary INSERT

**Postgres logical replication (Variant C rejected)**: Publications on the operator-action tables + subscriptions on shadow paths. Native, no code. Rejected for the same schema-divergence reason: logical replication doesn't cleanly handle target-schema restructures.

**Rewrite edge-api multi-DB-aware (rejected)**: Teach `edge-api` to fan out writes to 3 DBs. Highest lift; couples the refactor to changes in edge-api; extends to a coordinated deploy.

### Why Variant A wins

Variant A (dedicated Go service polling user_logs):
- **Handles schema evolution** — as the refactored schema diverges, we teach the Go service the new SQL per action type
- **Reuses proven mirror-worker patterns** (cursor, DLQ, exponential backoff) — high familiarity for future maintainers
- **Independently observable** — own metrics, own /healthz, own container logs
- **Loosely coupled** — a shadow-mirror crash doesn't affect the primary pipeline
- **Additive** — no changes to edge-api, oeecloud-worker, or mirror-worker

## Consequences

### Positive

- Flow 2 and Flow 3 finally receive operator-action data, enabling full-fidelity comparison against Flow 1
- Refactor POC validates not just the write path but also the full operator experience
- Clean separation: mirror-worker for prod→staging, shadow-mirror for staging→shadow paths, oeecloud-worker for data plane, edge-api for HTTP. Each service has one clear responsibility

### Negative

- +1 microservice to deploy + maintain + observe
- Each new operator-action category requires implementing a corresponding handler in shadow-mirror (v1 targets 6 handlers; long tail may accumulate)
- Cursor lag introduces small (~seconds) delay before an operator action reflects in shadow paths — accept for POC, not a real-time system

### Risks

- Handler drift — as edge-api adds new operator actions, shadow-mirror needs corresponding handlers. Requires PR-review discipline (a new `user_logs.category` string emitted from edge-api requires an accompanying shadow-mirror handler PR)
- Idempotency — replay must be safe on cursor-reset. All handlers use ON CONFLICT DO UPDATE or equivalent
- Shadow pool availability — if `packiot_shadow` is offline, shadow-mirror should degrade to writing only to `shadow_go_port` (partial degradation, logged)

## Implementation phases

### Phase 1 — skeleton (this session)
- Service scaffold at `services/shadow-mirror/`
- Config, dual pool (main + shadow), cursor, dispatcher
- Placeholder handler for one category (`manual-event-created`) — logs the intent, no writes yet
- Health + metrics + Dockerfile + compose entry
- Deployed to staging with default OFF (opt-in via env)

### Phase 2 — first 3 handlers (future sessions)
- `manual-event-created` — INSERT into `equipment_events_man` on both shadow paths
- `downtime-event-created` — INSERT into `downtimes` on both shadow paths
- `order-created-started` — INSERT into `production_orders` on both shadow paths

### Phase 3 — remaining handlers (future sessions)
- `order-stopped`, `order-replaced`, `order-changed`, `order-time-changed`, `order-status-changed`, `event-splitted`, `manual-event-edited`

### Phase 4 — production hardening (future)
- Retention policy on failure DLQ
- Alerting on cursor stall
- Documentation of the full mapping (event category → target table + SQL)

## References

- ADR-0010 — introduced source_type routing (shadow_go_port)
- ADR-0011 — durability contract (metrics + degraded /healthz)
- ADR-0012 — schema refactor (packiot_shadow)
- `services/mirror-worker-go/` — the reference implementation for the cursor + DLQ + dispatcher pattern
- `services/oeecloud-worker/` — the source_type routing pattern that shadow-mirror complements
