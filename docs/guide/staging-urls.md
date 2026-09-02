# Staging URLs — observability console

Verified links to watch stack health and confirm the refactored Go stack is
faithfully replicating **Incoplast** and **CPACK**, ahead of THE FLIP (#28).
Every link sits behind **Authentik SSO** (`auth.staging.packiot.app`); the
operator SPA then app-logs-in as `dev.cpack`.

> Reading order when triaging (same layering as `manual-smoke-check.md`):
> **13** (does data land?) → **08 / 10** (which hop?) → **09** (is it *correct*?)
> → **06 / 11** (logs for the guilty hop).

## The flip gate

- **[09 · Bake flow parity](https://grafana.staging.packiot.app/d/bake-flow-parity)**
  — `grafana.staging.packiot.app/d/bake-flow-parity`

Not a health board — the **flip gate itself**. Surface by surface, it shows
whether the flows agree (F1 legacy compute vs the Go flows). **Every surface
must hold `0.000`.** A non-zero reading is allowed only if it carries a *named,
dated* cause; a new unexplained non-zero stops the clock and the flip does not
proceed. Treat edits to board 09 as production changes.

## Is Incoplast & CPACK replicating?

| Board | Link | What to check |
|-------|------|---------------|
| 13 · Database reach | [`/d/database-reach`](https://grafana.staging.packiot.app/d/database-reach) | What lands on F1 / F2 / F3 — rows track for both tenants |
| 08 · oeecloud-worker | [`/d/oeecloud-worker-flow`](https://grafana.staging.packiot.app/d/oeecloud-worker-flow) | `batch_writes{tenant="incoplast"}` and `{tenant="cpack"}` non-zero across flows |
| 10 · edge-transformer | [`/d/edge-transformer-ingest`](https://grafana.staging.packiot.app/d/edge-transformer-ingest) | MQTT in → triple-emit at 1:1:1; no decode-error spike |
| 01 · OEE pipeline | [`/d/oee-pipeline`](https://grafana.staging.packiot.app/d/oee-pipeline) | Incoplast (ent 4) & CPACK equipment show live, sane OEE |
| 12 · Replay & fan-out | [`/d/replay-and-fanout`](https://grafana.staging.packiot.app/d/replay-and-fanout) | Replay lag low, DLQ shallow, **comparator divergence = 0** |
| 05 · Operator activity | [`/d/packiot-operator`](https://grafana.staging.packiot.app/d/packiot-operator) | An action fired in the SPA appears here, then replays to F3 |

### Ground truth — direct SQL (Adminer)

Browse the staging DBs at [`adminer.staging.packiot.app`](https://adminer.staging.packiot.app).
Run the same query against **`packiot`** (F1) and **`packiot_analytics`** (F3) — the
counts should track. Incoplast = `id_enterprise 4`; set it to CPACK's id for the
other tenant (confirm CPACK's enterprise id in Adminer first).

```sql
-- Incoplast (ent 4) ingest landing this hour — run in packiot (F1), then packiot_analytics (F3)
SELECT count(*) AS rows_last_hour
FROM equipment_values ev
JOIN equipments e ON e.id_equipment = ev.id_equipment
JOIN areas a      ON a.id_area      = e.id_area
JOIN sites s      ON s.id_site      = a.id_site
WHERE s.id_enterprise = 4
  AND ev.ts_value > now() - interval '1 hour';
```

```sql
-- Operator actions recorded for a tenant, last 24h (run in F1 = packiot)
SELECT category, count(*)
FROM user_logs
WHERE enterprise_id = 4
  AND created_at > now() - interval '24 hours'
GROUP BY category ORDER BY 2 DESC;
```

## All 13 Grafana boards

Base: `https://grafana.staging.packiot.app/d/<uid>`

| # | uid | Answers |
|---|-----|---------|
| 01 | `oee-pipeline` | Live business view — OEE per equipment |
| 02 | `equipment-config` | Equipment & PackML routing (packml_register) |
| 03 | `system-health` | DB & pipeline health, connections, disk |
| 04 | `packiot-logs` | Stack-wide log stream |
| 05 | `packiot-operator` | Operator actions → user_logs |
| 06 | `packiot-services-logs` | Logs filtered by service |
| 07 | `mirror-worker-flow` | Prod in → replay / fan-out (retires at flip) |
| 08 | `oeecloud-worker-flow` | AMQP in → engine → writes per flow (tenant label) |
| **09** | **`bake-flow-parity`** | **F1 vs Go parity — the flip gate** |
| 10 | `edge-transformer-ingest` | MQTT in → Calc → triple-emit |
| 11 | `packiot-pipeline-logs` | plc-sim → edge-transformer trace |
| 12 | `replay-and-fanout` | shadow-mirror + comparator divergence (retires at flip) |
| 13 | `database-reach` | What lands on F1 / F2 / F3 |

## Operate & inspect

| Tool | URL | Use for |
|------|-----|---------|
| Operator SPA | [operator.staging.packiot.app](https://operator.staging.packiot.app) | Fire a PO / downtime / split; then watch board 05 + the comparator |
| Adminer | [adminer.staging.packiot.app](https://adminer.staging.packiot.app) | Direct DB — switch between `packiot` (F1) and `packiot_analytics` (F3) |
| RabbitMQ mgmt | [rabbitmq.staging.packiot.com](https://rabbitmq.staging.packiot.com) | Queue depth, DLQ, per-tenant command queues (also `amqp.staging.packiot.app`) |
| ~~Hasura console~~ | _retired (audit 2026-08-21)_ | GraphQL engine removed — container/image/DNS gone; read-path served by refdata-api, front4/edge-api mutations moved native |
| Node-RED editor | [nodered.staging.packiot.com](https://nodered.staging.packiot.com) | Operator endpoints + sim flows (sim retires at flip) |
| Authentik | [auth.staging.packiot.app](https://auth.staging.packiot.app) | The SSO gate — re-auth here if a link 403s |

## Notes & gotchas

- **Grafana host is `.app`, not `.com`** — the `.com` apex appears in older docs,
  but basic auth is disabled and SSO is on `grafana.staging.packiot.app`
  (verified). Login is Authentik only; the `GRAFANA_ADMIN_PASSWORD` does **not**
  work in the web UI (break-glass reset via `docker exec` only).
- **Tenants**: Incoplast = `id_enterprise 4` (metric label `incoplast`). CPACK =
  the canonical test tenant (label `cpack`) — confirm its enterprise id in
  Adminer before running the per-tenant SQL for it.
- **Flows**: F1 `packiot`·public (legacy compute) · F2 `packiot`·shadow_go_port ·
  F3 `packiot_analytics`·public (refactored). The bake compares F1 vs F3.
- **Prod DB is SELECT-only, always.** This console watches **staging**; prod is
  untouched.
