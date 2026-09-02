# State of the stack & continuation guide

> The definitive handoff snapshot: every service's status, every URL,
> every dashboard, the database validation results, and exactly what
> remains. Written after a full-stack review on **2026-07-06 ~19:00Z**.
> If you are continuing this work (human or AI), start HERE, then
> [the guide](../README.md).

## 1. Service fleet (staging app EC2 `i-06c9547a2c7091ab7`)

Full sweep result: **25 containers, all healthy or intentionally
one-shot; ZERO error-level log lines across every service in the
sampled window.**

| Service | Status | Notes |
|---|---|---|
| oeecloud-worker | ✅ healthy | THE engine — all jobs green (see [guide ch.4](../guide/04-the-engine.md)) |
| edge-transformer | ✅ healthy | MQTT ingest, triple-emit; AMQP source deliberately OFF (10.9) |
| plc-sim | ✅ up | THE staging data source (Sparkplug B → Mosquitto) |
| mirror-worker-go | ✅ healthy | prod mirror; value-sync at designed steady state (attributed ledger) |
| shadow-mirror | ✅ healthy | operator replay + runtime windows + supersede |
| refdata-api / query-api | ✅ healthy | read side |
| edge-api, operator, edge-nodered | ✅ up | operator app path (nodered = operator endpoints only now) |
| mosquitto, rabbitmq, pgbouncer | ✅ healthy | mosquitto healthcheck occasionally flakes deploys — restart clears (known) |
| grafana, prometheus, loki, promtail | ✅ healthy | observability |
| hasura (+init) | ✅ healthy | retires at flip (R5) |
| authentik (server/worker/redis) | ✅ healthy | SSO gate for the SPA |
| adminer | ✅ up | DB browsing |
| stack-simulator-1 (legacy nodered sim) | ⚠ running, harmless | its residual publishes are counted-dropped; retire with R6/R7 at flip |
| db-migrate, hasura-init | ✅ exited(0) | one-shot by design |

DB EC2 `i-064bb36d1c454d861`: timescaledb up 4 weeks, disk 42% used
(38G free). Databases: `packiot` (F1 public + F2 shadow_go_port),
`packiot_analytics` (F3 — the flip target).

## 2. URLs (dev access)

| URL | What |
|---|---|
| grafana.staging.packiot.com | dashboards (see §3) |
| operator.staging.packiot.app | operator SPA (behind Authentik SSO; app login dev.cpack) |
| auth.staging.packiot.app | Authentik |
| rabbitmq.staging.packiot.com / amqp.staging.packiot.app | RMQ management |
| hasura.staging.packiot.com | Hasura console (retires at flip) |
| adminer.staging.packiot.app | DB browser |
| api.staging.packiot.com | edge-api |
| nodered.staging.packiot.com | Node-RED editor (operator endpoints; sim flows retire at flip) |

Shell access: AWS SSM to the two instance ids above (no SSH keys).
Prod DB (tsp12): `databaseCredentials` secret, **SELECT-only, always**.

## 3. Grafana dashboards

| Board | Use |
|---|---|
| **09-bake-flow-parity** | THE flip gate: fidelity mismatches + identity fingerprints + agreement %, reading discipline in-panel |
| 08-oeecloud-worker | engine jobs, writers, calc port, PO-control counters |
| 07-mirror-worker | mirror fidelity watchdog, DLQ, cursors |
| 10-edge-transformer | ingest/decode/outbox (renumbered from the old 09-shadow-mode name) |
| 11-pipeline-logs | plc-sim → edge-transformer hop (Loki) |
| 12-replay-and-fanout | shadow-mirror replay + value fan-out tiles |
| 13-database-reach | what actually lands on F1/F2/F3 (postgres) |
| 01-oee-pipeline · 02-equipment-config · 03-system-health · 04/06 logs · 05-operator | general ops |

(Renumbered scheme per `grafana/README.md` is canonical; the old
`09-edge-transformer-shadow-mode` / `10-3-flow-parity` names are gone —
a stale comment in `monitoring/prometheus/prometheus.yml` still
referenced the old 09 filename until the 2026-07-07 sweep.)

## 4. Database refactor validation (checked live)

| Item | Result |
|---|---|
| F3 core tables | ✅ 893 POs · 124 runtime windows · values/events flowing · 5,952 shift buckets |
| F3 `hist_*` (§5 history) | ✅ EV 2,410,531 · POs 20,627 · user_logs 137,150 |
| F3 UNS current | ✅ hour 20 filled · job 9 running POs |
| Descriptors | ✅ label_formats=2 · box_production_bridges=2 · boxes pool has rows |
| Identity F2↔F3 | ✅ converging by design: PO-runtime **sums EQUAL** (92,137=92,137), counts 73→68 closing; shift gross EQUAL (466,265 both) |
| Bake fidelity | ✅ shift surface at ZERO; week 12→3; remaining numbers all named + dated (day/month transitional; job surface under watch) |
| customer_reports pools (shift06/speed33) | ⚠ **EMPTY — EXPECTED, not broken**: the report fns read STAGING base data for enterprises 6/33, which has aged past the 21-day report windows (staging is CPACK-focused). Prod-fidelity was proven at port time (1197/1197 rows; 63/68 exact) via the prod-read harness. **Re-run that harness for the PowerBI sign-off** — recipe in `adr/reference/designs/` + Wave-2 notes in `0012-phase4-execution-plan.md` |

## 5. Remaining tasks (complete list)

**Clocks (self-running):**
- 7-day full-surface bake window → **~2026-07-14** (clock RESTARTED
  2026-07-07: the envelope-routing repairs of 07-06 — F2 double-write
  era, F1 gap + backlog replay — print artifacts on 3d comparison
  surfaces until ~07-09; count green days from 07-07) (started at the
  10.9 cutover; read 09-bake daily — every non-zero must keep its
  named cause).
- F3 identity fingerprints converge as its history fills (~07-09).
- Old-DB 30-day freeze starts at flip.

**Human-gated (the only blockers):**
1. PowerBI 37+1-object gate sign-off ([guides/powerbi-compatibility-test-plan](../guides/powerbi-compatibility-test-plan.md)) — re-run the prod-read report harness as evidence.
2. `sap_13` (issue #223): back4-api owner — port+bake or ledger-deferral.
3. `c35` dead dashboards (issue #224): drop sign-off.
4. Prod Hasura Cloud credentials (+ issue #225 month-boundary operations recheck).
5. 10.9 **prod** payload capture (real factory Sparkplug) — needed for prod's MQTT cutover, not staging's.

**Then execute (all pre-written):**
- The flip: [adr/reference/0016-flip-runbook.md](../adr/reference/0016-flip-runbook.md) (~30 min, reversible).
- Retirements R1–R9 (incl. stack-simulator-1, nodered sim flows, Hasura, shadow_go_port, dashboards 10 + 09-shadow-mode cleanup).
- Wave 4 contract after its 30-day soak (version-sprawl drops; evidence = pg_stat idx_scan baselines already collected in deploy CI).
- Phase VI: prod migration planning (elevated access; PowerBI + payload prerequisites above).

**Watch items (2026-07-07 full-stack audit — need a named cause or fate BEFORE flip):**
- **`uns_equipment_current_metrics` FROZEN on all 3 flows** (measured
  07-07 ~01:50Z: F1 stale since the 10.9 cutover ~07-06 14:00Z; F2/F3
  since ~07-03 22:00Z; 66 rows each; raw ingest live to the minute).
  Root cause: it is an ingest-time writer keyed to routing key
  `sparkplug.uns_metrics` (see oeecloud-worker
  `internal/handlers/dispatcher.go`), and post-10.9 the transformer
  publishes only `sparkplug.data`. The endstate map keeps this table
  (layer 5). Decide: emit the family from the transformer, move
  maintenance into the `uns` job, or re-scope the table — and name the
  cause on the bake board either way.
- Legacy Node-RED `Publish: oee (amqplib)` node (Sparkplug tab) is
  still ENABLED, publishing tenant-suffixed `sparkplug.data.<gateway>`
  into the unconsumed per-tenant queue (the known "counted-dropped"
  residual). Its bare-key fallback (gateway underivable) WOULD land in
  the consumed queue → at R6/R7: disable the tab, verify the tenant
  queue drained, and confirm the fallback never fired.

**Cosmetic/backlog (safe anytime):**
- Bloat-ledger items post-flip: amber-bug fixes (consumer-signed), runtime-table slimming, `monitoramento_*` drop.

## 5b. Alerting (added 2026-07-07)

Prometheus rule groups `packiot-staging-health` (#336) +
`packiot-flow-and-parity` cover: target down, engine stalls/errors,
ingest silence, write-path dry, **flow write imbalance** (the
2026-07-06 starving-leg class), batch errors, bake/identity
persistence past expiry, DLQ, MQTT loss. Firing alerts show on the
**03** and **09** boards' top panel (red = look). No external
notification channel yet — the panel IS the notifier; wiring
Slack/email needs a business decision on the channel.

Grafana access truth: **https://grafana.staging.packiot.app via
Authentik SSO** (basic auth is disabled; `GRAFANA_ADMIN_PASSWORD` is
break-glass only). API automation: `-H 'X-WEBAUTH-USER: admin'`
against the container's :3000.

## 6. How to continue a work session

0. **Shared-tree rule**: multiple sessions may work this repo
   concurrently — NEVER edit the main checkout for shippable work;
   `git worktree add <scratch> origin/staging`, branch, PR, remove.
1. Read the project memory pickup (`session_77_pickup.md` in the
   Claude project memory) — machine state + rules.
2. Read this file for the live snapshot; check 09-bake for anything
   past its expiry date (that's the only alarm that matters).
3. Golden rules: [guide ch.9 §principles](../guide/09-the-endgame.md). The three
   that prevent disasters: prod SELECT-only · call-site-verify before
   porting · one precise predicate per destructive cleanup.
4. The bug journal (260+ entries) and the zettel vault hold every
   lesson with its rule — search before re-deriving.
