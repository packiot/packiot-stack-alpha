---
title: Simulators, twins and edge tools
layer: 3
owner_area: edge
last_verified: 2026-09-28
---
# Simulators, twins and edge tools

> **Layer 3 · Components** — every program that *pretends to be a factory* (simulators, soft
> PLCs, tenant twins, test fixtures) plus the onboarding/capture CLIs that live next to them.
> Which are test-only, where they publish, and how they have hurt real data. For anyone about
> to run one of them on staging.
> Up: [Edge subsystem](../subsystems/edge.md)

## Responsibility

These tools are accountable for **producing realistic edge input without a real factory** —
for pipeline tests, onboarding rehearsals and demos — **without ever writing into a real
tenant's data**. That second half is the hard part: staging's mosquitto carries CPACK's live
feed, so anything that publishes under a real group is a second writer on real topics.

## At a glance

| Tool | Kind | Publishes to | Runs where | Test-only? |
|---|---|---|---|---|
| `plc-sim` | Continuous CPACK SparkPlug simulator | `spBv1.0/CPACK/{NBIRTH,NDATA}/plc-sim` on mosquitto | Staging, profile `plc-sim` (off unless selected) | Staging-only; **real CPACK group** |
| `s7-softplc` | Pure-Go S7 server (ISO-on-TCP :102) with a mutating DB100 | Serves S7 reads | Staging, profile `s7` | Yes |
| `numeric-sim` | Legacy numeric-counter tee (`counterData[{id,value}]`) | `POST <agent>/v1/counters` | Manual CLI (`go run`) | Yes |
| `bispharma-twin` | Long-running Bispharma twin, counters only | `spBv1.0/BISPHARMASTAGING/{NBIRTH,NDATA}/bispharmastaging-twin` | Staging, always in the stack, idles unless `BISPHARMA_TWIN_ENABLED=true` | Staging-only; **real tenant group** |
| `bispharma-box-scan-mock` | Appends box-scan rows every 30 s | Analytics DB via pgbouncer (`scripts/mock-bispharma-box-scans.sql`) | Staging, idles unless `BISPHARMA_BOX_SCAN_MOCK_ENABLED=true` | Staging-only; **real tenant data** |
| `inject-counter-fixture` | One-shot NBIRTH + NDATA | `spBv1.0/E2EFIXTURE/{NBIRTH,NDATA}/inject-test` | CI (deploy + manual workflow) | Yes, synthetic group |
| `simulator/` (Python) | PLC + operator simulator for the legacy Node-RED path | `POST edge-nodered:1880/plc-data` + edge-api operator calls | Staging profile `legacy-sim` (retired 2026-08-16) | Yes, retired |
| `capture-fixtures` | Records live SparkPlug messages as JSON golden-test inputs | Files under `testdata/fixtures/<scenario>/` | Manual CLI | Read-only |
| `onboard-gen`, `onboard`, `onboard-capture`, `onboard-import` | Onboarding generator / orchestrator / capture reconciler / Node-RED importer | Files only | Manual CLI | Read-only against the world |
| `derive-replay` | Runs raw-tag samples through the production derive stage | stdout | Manual CLI | Read-only |

Built into the `packiot-sparkplug-decoder` image (main `Dockerfile`): `plc-sim`, `s7-softplc`,
`bispharma-twin` (plus the readers, agent and dashboard). Everything else is run with
`go run ./cmd/<name>` from `services/sparkplug-decoder`, or built ad hoc in CI.

## Inputs & outputs

### plc-sim (`cmd/plc-sim`)

- Group `CPACK` (constant), edge node `PLC_SIM_EDGE_NODE` (default `plc-sim`).
- Topology (verified against staging `packml_register`): line own-streams L8 (eq 51, 120/min),
  L5 (47, 147), L3 (48, 140), L4 (49, 147); members L5/BREYER (idx 61, eq 53), L5/TEXA (65,
  eq 57), L3/PTH (81, eq 61), L4/TEXA (63, eq 63).
- Per line metrics: `…/Admin/Prod{Consumed,Processed,Defective}Count/<idx>/Unit`,
  `…/Status/MachSpeed`, `…/Status/StateCurrent` (mostly 6 = execute, occasional stops),
  `CPACK/SC/LINHAS/<line>/Status/Parameter30700` (self-referential index so Phase-9
  member-derivation never fires — the #456 single-writer rule).
- NBIRTH retained (QoS 0) on connect; NDATA every `PLC_SIM_TICK_SEC` (default 5).
- Subscribes to `spBv1.0/CPACK/DCMD/<edge node>`: a DCMD can override `MachSpeed` or set the
  PO parameter (ADR-0019 C1 command-channel loop); the sim re-births to show the change.
- `EMIT_DEFINITIVE_BIRTH` (default false) adds role-typed birth properties.

### s7-softplc (`cmd/s7-softplc`)

DB100 layout, big-endian, matching the `s7-reader` demo tags:

| Offset | Type | Tag | Behaviour per tick |
|---|---|---|---|
| 0 | DINT | ProdProcessedCount | `+SOFTPLC_PROCESSED_STEP` (20) |
| 4 | DINT | ProdConsumedCount | `+SOFTPLC_CONSUMED_STEP` (1) |
| 8 | REAL | MachSpeed | `SOFTPLC_SPEED` (42.5) with a small wobble |
| 12 | INT | StateCurrent | 6 (running) |

Env: `LISTEN_ADDR` (`:102`), `S7_DB` (`100`), `SOFTPLC_TICK_SEC` (`5`). Staging IP
172.18.0.33, `mem_limit 32m`. See [plc-readers](plc-readers.md#failure-modes) for why the
staging `s7-reader` beside it currently emits raw envelopes nobody consumes.

### numeric-sim (`cmd/numeric-sim`)

Flags only: `--url` (`https://localhost:9104/v1/counters`), `--key` (default env
`AGENT_INGEST_API_KEY`), `--group` (`BISPHARMA`), `--gateway` (`bispharma-edge`), `--ids`
(`164,165,166,167,168,169`), `--polls` (5), `--interval` (2 s), `--start` (40000), `--step`
(30, jittered), `--reset-at` (-1 = never), `--insecure` (true). It sends monotone absolute
totalizers, exactly the shape the agent's numeric translator expects.

### bispharma-twin (`cmd/bispharma-twin`)

| Env | Default (binary) | Staging compose | Effect |
|---|---|---|---|
| `BISPHARMA_TWIN_ENABLED` | `false` | `${BISPHARMA_TWIN_ENABLED:-false}` | Master gate; false ⇒ process idles |
| `TWIN_BROKER` | `tcp://mosquitto:1883` | same | Publishes straight to mosquitto (the app box cannot hairpin its own public `:8449`) |
| `TWIN_GROUP` / `TWIN_EDGE_NODE` | `BISPHARMASTAGING` / `bispharmastaging-twin` | same | Distinct edge node marks provenance |
| `TWIN_LINE` | `L01` | `ALL` | Lines to emit (single, CSV or ALL) |
| `TWIN_TENANT_CONFIG` | `/etc/packiot/tenants/bispharma.yaml` | same | Member count-index leaves come from this `raw_tag_map` (never unmapped) |
| `TWIN_INTERVAL_SEC` | `15` | `15` | NDATA cadence |
| `TWIN_RATE_PER_MIN` | `600` | `50` | Per-machine throughput (kept below rated speed so Performance stays 0.3–0.9) |
| `TWIN_SCRAP_RATE` | `0.03` | `0.03` | Scrap fraction |
| `TWIN_STOP_PROB` / `_MIN_SEC` / `_MAX_SEC` | `0.03` / `120` / `600` | same | Freeze a line's counters to simulate stops (downtime is derived from count silence) |
| `TWIN_STATE_FILE` | *(empty)* | `/var/lib/bispharma-twin/totalizers.json` (volume `bispharma-twin-state`) | Resume totalizers after restart |
| `TWIN_CLIENT_ID` | `bispharma-twin` | — | MQTT client id |

Counters only (gross/net/scrap member leaves); no `MachSpeed` / `StateCurrent`. Re-births on a
Rebirth NCMD. Staging IP 172.18.0.48, `mem_limit 64m`.

### inject-counter-fixture (`cmd/inject-counter-fixture`)

One-shot: connects, publishes an NBIRTH (alias 1 `…/ProdConsumedCount/1/Unit`, alias 2
`MachSpeed`, alias 3 line `Parameter30700="1"`) and an NDATA with `--value`, then exits. All
names live under `E2EFIXTURE/SITE/AREA/LINE1/…`, which no tenant registers, so the decoder
exercises the full path (alias table, Calc port, outbox) but nothing resolves to equipment.
Flags: `--broker` (`tcp://localhost:1883`), `--value` (100), `--client-id`
(`edge-transformer-inject`).

Used by `.github/workflows/deploy-staging.yml` (post-deploy smoke, and the outbox chaos test
that stops RabbitMQ and injects 5 messages) and by the manual
`.github/workflows/inject-counter-fixture.yml`.

## Internal design

All Go producers share `internal/sparkplug` (encode, `SimMetric`, `EncodeSim`) and publish via
paho. The key design choice is **where** each one enters the pipeline:

```text
 numeric-sim ──HTTP /v1/counters──► sparkplug-agent ──┐
 s7-softplc ◄─S7── s7-reader ──(raw or SparkPlug)──────┤
 plc-sim ─────────SparkPlug (group CPACK)──────────────┼──► mosquitto ──► sparkplug-decoder
 bispharma-twin ──SparkPlug (group BISPHARMASTAGING)───┤
 inject-counter-fixture ──SparkPlug (group E2EFIXTURE)─┘
 simulator/ (retired) ──HTTP /plc-data──► edge-nodered (retired)
```

Anything that enters at mosquitto under a real group is indistinguishable, downstream, from
the real feed except by `edge_node_id` in decoder logs.

## Configuration

Covered per tool above. The staging selector for the CPACK source is `COMPOSE_PROFILES`
(GitHub Actions env / `/opt/packiot/.env`): `plc-sim` (sim on) **or** the real tee. Never both:
the two scopes are the same eight equipments `{47,48,49,51,53,57,61,63}`
(`compose.staging.yml` comment).

## Data & invariants

- **One writer per topic.** A synthetic producer must use a group that no tenant registers,
  or be switched off whenever the real producer for that group is live.
- **Enforced by a test, not a comment.**
  `cmd/inject-counter-fixture/main_test.go` `TestFixturePublishesOnlyUnderSyntheticGroup`
  fails if any fixture metric leaves the `E2EFIXTURE/` prefix, or if any
  `docs/clients/tenants/*.yaml` declares `group_id: E2EFIXTURE`. (The comment in `main.go`
  refers to a `fixtureGroupAllowed` guard; no function by that name exists — the test is the
  guard.)
- Twins carry a distinct `edge_node_id`; that marks provenance but does **not** prevent
  double-counting. Disabling the twin does.

## Observability

- plc-sim / twin logs: `NBIRTH published`, `DCMD listener subscribed`,
  `connected + NBIRTH published`, `member count-index leaves resolved (lines=, metrics=)`,
  `bispharma-twin DISABLED … idling`.
- Decoder logs attribute each publish to `GROUP/edge_node` (e.g.
  `BISPHARMASTAGING/bispharmastaging-twin`), the fastest way to spot a synthetic writer.
- CI: `calc_evaluations_total` on the decoder's `:9102/metrics` before/after the inject.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| **Synthetic writers on real CPACK topics (found 2026-09-25)** | CPACK L5 PO 897120 showed 278,483 produced vs legacy 43,286; line net = gross; L5 net rows 123/day vs TEXA 3,127 | (a) a `twin-injector` container running the fixture binary, `+7` every 30 s from 2026-08-31 to 2026-09-25; (b) the deploy/manual inject steps publishing values 100–600 on the real `CPACK/SC/LINHAS/L5/BREYER` topics; (c) an earlier July synthetic stream. Each fake value reset BREYER's totalizer state, so the next real reading became a huge increment (~6× inflation); the fixture's `Parameter30700="61"` also overrode the register seed so L5 net was metered from BREYER (gross-only) | PR #1460 moved the fixture to group `E2EFIXTURE` with the guard test; the twin-injector was stopped and later reaped by `--remove-orphans`; silver was repaired from backups on 2026-09-27 (`ops._bkp_l5_injector_20260925`, `ops._bkp_texa_injector_20260927`, `ops._bkp_sbx_l5_injector_20260927`) |
| Double-sourced CPACK (ent 3) | Counts roughly doubled | `plc-sim` resurrected by a deploy while the real tee/agent also ran | `plc-sim` is profile-gated; pick exactly one source in `COMPOSE_PROFILES` |
| Bispharma twin + real box both live | Doubled totalizers for ent 5 | Twin left enabled after the real feed returned | Set `BISPHARMA_TWIN_ENABLED=false` and recreate |
| Twin restart makes a one-time spike | Big delta row | Totalizers reset to 0 | `TWIN_STATE_FILE` on the named volume (configured on staging) |
| Twin OEE availability pinned at 100 % | No downtime events | Counters never stop | `TWIN_STOP_PROB > 0` (default 0.03) |
| Legacy simulator floods ent 4 | F1/F3 parity broken (2026-07-09) | Simulator PLC leg emitted for Incoplast, which had a real tee | `SIM_SKIP_ENTERPRISE_IDS=3,4`; simulator now retired |
| Static-IP collision on redeploy (2026-07-09, 2026-07-17) | "Address already in use", deploy stalls | Unpinned sim containers took a static service's IP during a recreate | Every sim service now has a pinned `ipv4_address` |

Rule from the 2026-09-25 incident: **a totalizer spike on one machine plus "net = gross" on
its line ⇒ look for a second writer on the same topic before blaming decoder math.**

## Operating it

- CPACK sim on staging: set `COMPOSE_PROFILES` to include `plc-sim` (and not the tee), deploy.
- S7 end-to-end: `docker compose -f compose.staging.yml --profile s7 up -d s7-softplc s7-reader`.
- Bispharma twin: set `BISPHARMA_TWIN_ENABLED=true` in `/opt/packiot/.env`, then
  `docker compose -f compose.staging.yml up -d --force-recreate bispharma-twin`
  (`docker restart` does not pick up the new env).
- Numeric tee test: `go run ./cmd/numeric-sim --url https://<agent>/v1/counters --group <G>`.
- Onboarding: `go run ./cmd/onboard-gen --descriptor docs/clients/<t>.descriptor.yaml --out
  gen/` (add `--cutover` to refuse inferred count indices); `go run ./cmd/onboard run
  --descriptor …` for the guided describe → generate → capture → validate flow.
- **Never** point any of these at a production broker, and never add a publisher under a real
  group without an off switch and a test.

## Tests

```bash
cd services/sparkplug-decoder
go test ./cmd/plc-sim/... ./cmd/bispharma-twin/... ./cmd/inject-counter-fixture/... \
        ./cmd/derive-replay/... ./internal/s7/softplc/...
```

- `cmd/plc-sim/feed_magnitude_parity_test.go` pins line `MachSpeed` to prod-calibrated bands;
  `main_test.go` checks the self-referential `Parameter30700` never collides with a member
  index; `definitive_birth_test.go` covers birth properties.
- `cmd/bispharma-twin/main_test.go`, `cmd/inject-counter-fixture/main_test.go` (group guard).

## Source map

| Path | What's there |
|---|---|
| `services/sparkplug-decoder/cmd/plc-sim/` | CPACK simulator, DCMD loop |
| `services/sparkplug-decoder/cmd/s7-softplc/`, `internal/s7/softplc/` | Soft PLC |
| `services/sparkplug-decoder/cmd/numeric-sim/` | Numeric tee simulator |
| `services/sparkplug-decoder/cmd/bispharma-twin/` | Bispharma twin |
| `services/sparkplug-decoder/cmd/inject-counter-fixture/` | CI fixture + group guard test |
| `services/sparkplug-decoder/cmd/capture-fixtures/` | Golden-fixture capture |
| `services/sparkplug-decoder/cmd/onboard*/`, `cmd/derive-replay/` | Onboarding and derive tooling |
| `simulator/` | Retired Python simulator (`simulator.py`, `devctl.py`) |
| `compose.staging.yml` (`plc-sim`, `s7-softplc`, `bispharma-twin`, `bispharma-box-scan-mock`, `simulator`) | Staging wiring and profiles |
| `.github/workflows/deploy-staging.yml`, `.github/workflows/inject-counter-fixture.yml` | Fixture use in CI |
| `docs/clients/bispharma-twin-staging-producer.md` | Twin background |
