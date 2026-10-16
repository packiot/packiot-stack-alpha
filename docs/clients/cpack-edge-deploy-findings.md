# CPACK edge bundle — deploy findings & patch log (2026-08-06)

First full end-to-end deploy test of the **generated** config-as-data edge bundle on
the real CPACK factory box (`packiot@10.135.1.173`, `~/cpack-edge`). Goal: prove
factory PLCs → Node-RED reader → sparkplug-agent → mTLS uplink :8883 → cloud
decoder → `equipment_values` (ent 3), using **only** the artifact the generator
produced.

Every hop broke on a distinct generator/bundle bug. We hot-fixed each on the box
to get data flowing; **the box fixes are ephemeral** (they live in the
`nodered-data` volume's `/data/flows.json` and the hand-edited `.env`) — the
durable fixes below must land in the generator before the bundle is truly turnkey.

Pipeline: `Node-RED reader` → `POST /v1/tags` → `sparkplug-agent` → `mTLS uplink`
→ `cloud mosquitto :8883` → `edge-transformer decoder` → `equipment_values`.

---

## Findings, in pipeline order

### F0 — bundle artifact is missing `.env.example` (dotfile drop)
- **Symptom:** no `.env` template in the downloaded bundle; nothing to fill in.
- **Root cause:** `actions/upload-artifact@v4` **excludes dotfiles by default**.
- **Box fix:** reconstructed the full `.env` by hand.
- **Durable fix:** add `include-hidden-files: true` to the upload step in
  `.github/workflows/generate-client-bundle.yml`.

### F1 — Node-RED base image has no PLC palette nodes
- **Symptom:** `Waiting for missing types to be registered: modbus-client,
  modbus-read, s7 endpoint, s7 in, OpcUa-Endpoint, OpcUa-Item, OpcUa-Client` —
  the reader flow never starts, no PLC polling.
- **Root cause:** `NODERED_IMAGE=nodered/node-red:4.0` is vanilla; the reader flow
  needs `node-red-contrib-s7`, `node-red-contrib-modbus`, `node-red-contrib-opcua`.
- **Box fix:** `docker exec edge-cpack-nodered sh -c "cd /data && npm install
  node-red-contrib-s7 node-red-contrib-modbus node-red-contrib-opcua"` + restart.
- **Durable fix:** ship a Node-RED image with these contrib nodes baked in
  (the client edge-node-red image), or install-on-first-boot in the compose entry,
  or add a `packages` list to `/data` provisioning. Do NOT rely on the vanilla image.

### F2 — agent `uplink_broker` pointed at the local broker
- **Symptom:** agent connected to `tcp://mosquitto:1883` (the on-box broker), never
  crossed the WAN to the cloud.
- **Root cause:** descriptor `agent.uplink_broker` was `tcp://mosquitto:1883`
  (same as `internal_broker`).
- **Box fix:** `sed` in `cpack/cpack-agent.yaml` →
  `uplink_broker: ssl://ingest.prod.packiot.app:8883` (internal_broker stays local);
  also corrected in the DB descriptor via `jsonb_set(... '{agent,uplink_broker}')`.
- **Durable fix:** generator default — `internal_broker` = local `tcp://mosquitto:1883`,
  `uplink_broker` = the cloud `ssl://<ingest-host>:8883`. Never emit them equal.

### F3 — compose can't interpolate `${TENANT_UPPER}_INGEST_KEY` as an env KEY
- **Symptom:** reader POSTs get `401 unauthorized`; container env shows a var
  **literally named** `${TENANT_UPPER}_INGEST_KEY` (un-interpolated), so
  `env.get("CPACK_INGEST_KEY")` returns nothing → empty key sent.
- **Root cause:** `compose.edge.yml` nodered service has
  `environment: ${TENANT_UPPER}_INGEST_KEY: ${AGENT_INGEST_API_KEY:?...}`.
  **Docker Compose does not interpolate variables in the KEY position of an
  `environment:` mapping** — only in values. (Same trap hit in session 94.)
- **Box fix:** appended a real `CPACK_INGEST_KEY=<AGENT_INGEST_API_KEY value>` to
  `.env` (env_file passes concrete names straight through) + recreate nodered.
- **Durable fix:** the tenant is known at generation time — emit the **concrete**
  key name: `CPACK_INGEST_KEY: ${AGENT_INGEST_API_KEY}`. No variable in the key.

### F4 — reader-gen omits the `X-Ingest-Key` header
- **Symptom:** even with the key present, still `401`; the reader never sent an
  auth header.
- **Root cause:** the generated `cpack_reader_norm` function sets
  `msg.headers = { "Content-Type": "application/json" }` — no `X-Ingest-Key`.
  The agent (`httpingest.go`) **requires** it (constant-time compare; an empty
  server key is a programming error, `main` refuses to start). The manual-tee
  template (`generate.go:356`) *does* add the header; the reader-gen dropped it.
- **Box fix:** patched the function →
  `"X-Ingest-Key": env.get("CPACK_INGEST_KEY")` in `msg.headers`.
- **Durable fix:** reader-gen must emit the same auth header the tee template does.

### F5 — reader-gen emits the wrong envelope shape (Tier-1 ↔ Tier-2 contract drift) ⚠️
- **Symptom:** `tags accepted accepted:0 total:0 bytes:496` — auth OK, but the
  decoder read **zero** tags from a non-empty body.
- **Root cause:** the reader emits
  `{ timestamp, gateway, metrics:[{name, value, timestamp}] }`, but
  `rawtag.Decode` reads **only** `{ endpoint, scan_ts, tags:[{metric, value, ts}] }`
  (no `metrics` alias, no custom unmarshal). Field-for-field mismatch:
  `metrics`→`tags`, `name`→`metric`, `timestamp`→`ts`, `gateway`→`endpoint`, +`scan_ts`.
  **The tee template (`generate.go:347`) also emits `{timestamp, gateway, metrics}`**
  — so *both* Node-RED producers are on the wrong side of the Go decoder contract.
- **Box fix:** reshaped the payload in the function:
  `{ endpoint:"cpack-edge", scan_ts: ts, tags: metrics.map(m => ({metric:m.name, value:m.value, ts:m.timestamp})) }`.
- **Durable fix:** define ONE wire contract (the `rawtag` envelope) and generate
  both the reader-gen and the tee template against it. This is the most important
  fix — it's a silent data-loss bug (200 OK, zero tags decoded).

### F6 — reader-gen doesn't strip the canonical prefix to the suffix
- **Symptom:** `total:6/7/12` (envelope decodes) but `accepted:0` — every tag
  dropped as unmapped.
- **Root cause:** the agent tag_map is keyed by **`metric_suffix`**
  (`agentcfg.go:157 m[e.MetricSuffix] = e`); full canonical = `packml_topic` + suffix.
  For CPACK, `packml_topic: CPACK/SC` and suffixes look like
  `/CELULA1/CER400/CER400/Admin/ProdProcessedCount/107/Unit`. But the reader emits
  the **full** canonical topic as `metric`
  (`CPACK/SC/CELULA1/CER400/CER400/Admin/ProdProcessedCount/107/Unit`), so the
  suffix lookup misses on all of them. (This is the "reader strips canonical_prefix"
  step flagged in the config-as-data epic review.)
- **Box fix:** `metric: m.name.replace("CPACK/SC","")` in the map (strip prefix →
  suffix; keeps the leading `/`).
- **Durable fix:** reader-gen must emit `metric` = suffix (strip the `packml_topic`
  prefix), matching the resolver's suffix keying. Alternatively the resolver could
  accept full canonical and strip internally — but pick ONE side and make the
  generator + decoder agree.

### Minor / operational tweaks
- **Stale containers:** `up -d` didn't recreate old session-94 containers →
  `--force-recreate` needed. (Compose only recreates on config/image change; the
  image tag hadn't changed in the container's eyes.)
- **PLC host IPs + ingest key:** hand-added 11 `PLC_HOST_*` and an
  `openssl rand -hex 32` ingest key to `.env`. PR #738 (turnkey) is meant to seed
  these from the descriptor `host_ref`s + auto-gen the key at bundle time.
- **Go missing on the self-hosted runner** (bundle build) → installed Go 1.25.0 live,
  codified in `app_init.sh` (#735).

---

## The flow-patch stack (ephemeral — applied to `/data/flows.json` on the box)

All four reader-flow fixes below were applied live to the running
`edge-cpack-nodered` (function node `cpack_reader_norm`). They are **NOT** in the
bundle and will be **lost if the `nodered-data` volume is recreated**. Backup at
`/data/flows.json.bak` (pre-patch). Re-apply order if the volume is wiped:

1. **F4** header: add `"X-Ingest-Key": env.get("CPACK_INGEST_KEY")` to `msg.headers`.
2. **F5** envelope: `msg.payload = { endpoint:"cpack-edge", scan_ts: ts, tags: metrics.map(m => ({metric:m.name, value:m.value, ts:m.timestamp})) }`.
3. **F6** suffix: inside the map, `metric: m.name.replace("CPACK/SC","")`.

Net `cpack_reader_norm` tail after all three:
```js
if (metrics.length === 0) { node.warn("reader: no numeric tags; skipping"); return null; }
msg.url = url;
msg.headers = { "Content-Type": "application/json", "X-Ingest-Key": env.get("CPACK_INGEST_KEY") };
msg.payload = { endpoint: "cpack-edge", scan_ts: ts,
  tags: metrics.map(function(m){ return { metric: m.name.replace("CPACK/SC",""), value: m.value, ts: m.timestamp }; }) };
return msg;
```

Plus, outside the flow:
- **F1** contrib nodes installed in `/data/node_modules` (also volume-resident).
- **F2** `cpack/cpack-agent.yaml` `uplink_broker` → `ssl://ingest.prod.packiot.app:8883`.
- **F3** `.env` gained `CPACK_INGEST_KEY=<same as AGENT_INGEST_API_KEY>`.

---

## Durable fix checklist (for polishing the turnkey generator)

PR in flight: `feat/reader-gen-rawtag-turnkey-fixes` (reader-gen + compose + workflow).

- [~] F0 `upload-artifact@v4` → `include-hidden-files: true` — *in PR*
- [x] F1 Node-RED contrib nodes — DURABLE: baked into `packiot/nodered-reader:4.0`
      (`docs/clients/edge-deployment/Dockerfile.nodered-reader`, pins s7@3.1.3 /
      modbus@5.45.0 / opcua@0.2.354), embedded in the bundle via `docker save`; the
      seed's install-on-boot stays as a self-heal fallback for a vanilla NODERED_IMAGE
      override only. (superseded the install-on-boot-only fix)
- [ ] F2 generator: `uplink_broker` = cloud `ssl://…:8883`, never = internal_broker
      (descriptor-level default; fixed live in the DB descriptor already)
- [~] F3 reader reads the concrete `AGENT_INGEST_API_KEY` (no `${VAR}` env KEY) — *in PR*
- [~] F4 reader-gen: emit the `X-Ingest-Key` header — *in PR*
- [~] F5 **reader-gen only**: emit the `rawtag` envelope
      (`{endpoint, scan_ts, tags:[{metric, value, ts}]}`). CORRECTION: the tee template
      is CORRECT as-is — it targets the ingest-shim (`sparkplug.Parse`), a different
      contract. Only the reader (→ agent `/v1/tags`) was wrong. — *in PR*
- [~] F6 reader-gen: emit `metric` = suffix (strip `Descriptor.Canonical.Prefix`) — *in PR*
- [ ] F7 turnkey (#738): seed `PLC_HOST_*` + auto-gen `AGENT_INGEST_API_KEY` at bundle time

Cloud-side follow-ups (separate from the bundle):
- [ ] G1 `oeecloud-worker` on new-prod: stop routing refactored writes at the dropped
      `shadow_go_port` schema — write to main/public (single-flow prod has no shadow).
- [ ] G2 increment sanity clamp: seed a baseline on the first observed totalizer.

**Regression guard idea:** a single golden test that runs the *generated* reader
function's `msg` through `rawtag.Decode` + the resolver and asserts
`accepted == total` for a known descriptor. That one test would have caught F4, F5,
and F6 at once.

---

## Cloud-side findings (NOT the bundle — new-prod stack config)

Proven end-to-end past the edge: factory PLCs → reader → agent (`accepted==total`)
→ mTLS :8883 → cloud mosquitto → `edge-transformer` decoder
(`sparkplug: data decoded`, seq incrementing, `metric_count` 18-23) → RabbitMQ →
`oeecloud-worker` (processing eq 56/57/69/87/98…). But `equipment_values` stays
empty for ent 3 because of two **cloud-stack** bugs:

### G1 — dead `shadow_go_port` "go" leg poisons the production write ⚠️ (real root cause)
- **Symptom:** worker log
  `upsert shadow_go_port.equipment_values (consumed) … ERROR: relation
  "shadow_go_port.equipment_values" does not exist (SQLSTATE 42P01)` →
  `handler error, nacked to retry` → `public.equipment_values` stays empty for every
  enterprise.
- **Root cause (precise):** the edge-transformer handler (`cmd/edge-transformer/main.go`
  ~line 1438) emits `sourceTypes := []string{"go"}` **unconditionally** (then appends
  `"refactored"` when `SHADOW_EMIT_REFACTORED=true`). The worker's `routeForSource`
  (`internal/handlers/sparkplug.go:410`) maps `"go"` → (main pool, **`shadow_go_port`**)
  and `"refactored"` → (main pool, **`public`**, fallback since no shadow pool). The
  `"go"` leg is processed **first**; on new-prod `shadow_go_port` doesn't exist
  (dropped session 92, never created on fresh prod), so that write errors, the handler
  returns the error, and the **entire message is nacked** — the `"refactored"→public`
  write in the same handler pass never commits. A dead staging comparator leg is
  aborting the production write. There is **no env gate** to suppress the `"go"` leg
  (checked `origin/production`; no `SHADOW_EMIT_GO`).
- **NOT the clamp:** the increment sanity clamp only "emits 0" (writes a clamped row),
  it does not skip the write — so G2 is not why rows are missing.
- **Fix (cloud code + redeploy, not bundle):** stop the dead leg from poisoning prod.
  Options: **(a)** add a `SHADOW_EMIT_GO` gate to the decoder (default true; set false
  on single-flow new-prod) — cleanest, don't emit what prod doesn't consume;
  **(b)** make the worker's `shadow_go_port` write non-fatal (log + continue) so a
  missing shadow schema can't nack the production write — defensive belt-and-suspenders.
  Recommend (a) + (b). Requires a PR (staging→promote) + new-prod redeploy.

### G2 — increment sanity clamp rejects absolute totalizers on first boot
- **Symptom:** `increment sanity clamp REJECTED implausible production increment
  observed:674329 bound:588 rate_per_min:147`.
- **Root cause:** PLC counters are absolute totalizers; on first boot there's no
  baseline, so the first observed value (674329) reads as an implausible one-scan
  jump. This is the known "totalizers heal past the horizon" first-boot case.
- **Fix (cloud/design):** seed a baseline on first observation (accept + set the
  reference, don't clamp the very first sample), or widen the first-boot bound.

**Bottom line:** the **bundle/edge artifact is proven**. G1+G2 are new-prod cloud
config/first-boot issues, tracked separately from the turnkey generator work.

### G1 — FIXED + DEPLOYED (2026-08-07)
- PRs #741 (remove orphaned `dualpath_equivalence_test.go`, unblock CI), #740
  (`SHADOW_EMIT_GO` decoder gate + worker swallow of missing-shadow-schema error +
  `compose.production.yml` `SHADOW_EMIT_GO=false`), #739 (bundle turnkey) — all merged
  to staging, promoted to production, and `deploy-production.yml` ran green.
- Verified live on new-prod: `SHADOW_EMIT_GO=false`, decoder still decoding CPACK
  (seq advancing), and the ingest-path `shadow_go_port` **nacks are gone** — the
  `"refactored"→public` write is no longer poisoned. Root cause resolved.

### Why `equipment_values` is still 0 — line is IDLE, not a bug
- The decoder's Calc port drops EVERY CPACK counter (`calc_evaluations_total{outcome=
  "drop"}`, 0 emits) — `calc_state_mutations` advance (counters recorded each scan) but
  no delta is emitted. That is the idle signature: absolute totalizers static, no
  production increment to difference. Pre-deploy, the clamp caught the single first-boot
  observation (`674329`); after that seed, every scan is a zero-delta drop.
- CPACK's Node-RED reader is **counter-only** (the S7/Modbus vartables are ~all
  `ProdConsumed/ProcessedCount/Unit`; only Flexo carries a `MachSpeed`). With
  `CALC_CUTOVER_REFACTORED=true` the raw counters are replaced by Calc deltas, so with
  the line idle the cutover envelope carries essentially nothing → no `equipment_values`.
- **Expectation:** `equipment_values` for ent 3 will populate once CPACK is in
  production (counters increment → Calc emits deltas → worker writes public). Confirm
  during a known production window. The write path is unblocked and correct.

### G3 (new) — worker runs `shadow_go_port` background jobs on new-prod
- After the G1 fix the ingest nacks stopped, but the worker's periodic jobs still target
  `shadow_go_port.*` (`runtime-rollup`, `area-hour`, `dq-scan`, `silver-clamp`,
  `hour-backfill`, `uns-current-metrics`) → repeated `42P01` **WARN**s. Non-fatal (they
  don't block ingest) but noisy. Single-flow new-prod should not run the F2/shadow_go_port
  rollup loops — gate them off (or point at the main schema) for a single-flow deploy.

### G2 (still open) — first-boot clamp
- The first real production increment after boot may be clamped like the `674329`
  first-observation until a baseline settles. Seed the baseline on first observation.

### G4 (NEW — the real remaining blocker) — Calc-cutover drops INCREMENTING counters
- **Proven with live box data (2026-08-07):** the CPACK line IS producing — multiple
  counters increment steadily (~30-40/15s scan), captured directly via a temporary
  reader tap over SSH (`packiot@10.135.1.173`, password auth, key not authorized):
  `L10/DXL/ProdProcessedCount 308185→308339`, `L3/BREYER 550228→550367`,
  `L6/TEXA 51938→52123`, `BREYER2 493887→494000`, `SLEEVE2 94725→94838`, … (others
  idle: L5, L8/DXL, L4, BREYER1=0; `L8/PTH=32767`=INT16 saturated).
- **But the decoder's Calc port drops EVERY counter** (`calc_evaluations_total{outcome=
  "drop"}`, 0 emits) — so the refactored/cutover envelope carries 0 counters (only the
  Flexo `MachSpeed=634` non-counter trickles through) → `equipment_values` never fills.
- **Root cause (strong lead, not yet fixed):** `calc.go` emits a counter only when
  `cur > prev` (line 273); it drops when `cur == prev`. `CmdTrigger` IS set
  (`main.go:969`), the topics parse (kind label present), and no SETUP mode. Yet all
  drop, and `calc_state_mutations_total` (323) ≈ the drop count — i.e. the state Calc
  reads as `prev` is being advanced to `cur` BEFORE the delta is computed, so
  `cur == prev` always → no increment detected. Investigate the decoder's Calc
  invocation + state read/update ordering (who writes the counter state vs. when
  `state.Int(topicProcessed)` is read). This is the actual gate on live OEE for CPACK.
- Consistent with CPACK being **counter-only** (reader reads no StateCurrent) + the
  count-indexed `/NNN/Unit` topic shape — verify the Calc state keying handles the
  count-index sibling-topic derivation (`replaceCounterName`) for these topics.

### G4 — FIXED + VERIFIED LIVE (2026-08-07)
- Root cause: `COUNTERS_ONLY_OEE_ENABLED` was unset on the new-prod decoder, so the
  Phase-8 glitch guard `prodSpeed < 3*machSpeed` ran with machspeed=0 (CPACK has no
  MachSpeed sensor) → `prodSpeed < 0` → dropped every counter. The compose even had a
  placeholder comment: *"OMITTED … set per-client at onboarding IF the client is a
  Modbus/counters-only line"* — a real onboarding TODO that was never filled.
- Fix: `COUNTERS_ONLY_OEE_ENABLED=true` + `COUNTERS_ONLY_IDEAL_RATES` (JSON map of the
  18 registered CPACK unit topics → `equipments.production_speed` parts/min). Guard then
  uses `3*IdealRate`. Applied live via `.env` hotfix + recreate → **`calc` outcomes went
  from 100% drop to `send`, and `equipment_values` filled (47 rows / 3 producing equips,
  fresh ts).** Codified durably in `compose.production.yml` via **PR #742**.
- **Durable follow-up:** source the rates from the DB (`production_speed`) at decoder
  boot instead of a static per-client env map, so CS-Admin speed edits flow automatically
  (config-as-data). Today's map goes stale if speeds change.
- **Onboarding lesson:** any counter-only client (Modbus/S7, no MachSpeed) MUST get
  counters-only + rated speeds set at onboarding, or OEE silently stays at zero.

## Production-readiness tracker (running list of durable stack updates)

Everything discovered turning the generated CPACK bundle into a live, OEE-producing
edge. ✅ = landed, 🟡 = PR open / needs deploy, ⬜ = follow-up.

| # | Item | Where | Status |
|---|------|-------|--------|
| F0 | `upload-artifact@v4 include-hidden-files:true` (ship `.env.example`) | generate-client-bundle.yml | ✅ #739 |
| F1 | Node-RED image needs s7/modbus/opcua contrib nodes (install-on-boot) | compose.edge.yml | ✅ #739 |
| F2 | descriptor `uplink_broker` = cloud `ssl://…:8883`, never internal | descriptor default | 🟡 fixed in DB; generator default ⬜ |
| F3 | reader reads concrete `AGENT_INGEST_API_KEY` (no `${VAR}` env KEY) | generate_reader.go + compose.edge.yml | ✅ #739 |
| F4 | reader-gen emits `X-Ingest-Key` header | generate_reader.go | ✅ #739 |
| F5 | reader-gen emits `rawtag` envelope `{endpoint,scan_ts,tags}` | generate_reader.go | ✅ #739 |
| F6 | reader-gen strips tenant prefix → suffix for `metric` | generate_reader.go | ✅ #739 |
| F7 | turnkey: DB-sourced descriptor + auto-gen ingest key at bundle time | #738 | ✅ #738 (merged) |
| F8 | bundle DB-read: build DSN from components (`production/db` has no `.url` → silent fallback to stale descriptor = F2 regression) | generate-client-bundle.yml | ✅ #744 |
| F9 | multi-PLC per-endpoint host prefill (today CS fills `PLC_HOST_*`; generator only prefills a single fallback host) | generate-client-bundle.yml | ⬜ (turnkey follow-up) |
| G1 | gate dead `go`/`shadow_go_port` leg so it can't nack prod writes | edge-transformer + oeecloud-worker | ✅ #740 (deployed) |
| G2 | increment clamp: seed baseline on first observation | oeecloud-worker | ⬜ |
| G3 | worker runs `shadow_go_port` background rollup jobs on single-flow prod | oeecloud-worker | ⬜ (WARN-only) |
| G4 | enable counters-only OEE + rated speeds for CPACK | compose.production.yml | ✅ #742 (deployed + verified: equipment_values fills) |
| G5 | reader-gen is counter-only — no StateCurrent/MachSpeed read; some equips unregistered in packml_register | descriptor / reader-gen | ⬜ (limits which equips emit) |
| — | source counters-only rates from DB at boot (retire static map) | edge-transformer config | ⬜ (G4 follow-up) |
| — | regression test: generated reader `msg` → `rawtag.Decode` → resolver asserts `accepted==total` | edge-transformer tests | ⬜ |
| — | CS Admin fields for bundle setup | csadmin | see `csadmin-bundle-setup-gaps.md` |

## Deploy summary (2026-08-07)
- PRs #741, #740, #739 merged to staging (admin path blocked; got CI to fire via a
  branch push, merged clean), promoted staging→production, `deploy-production.yml` green.
- Verified live: `SHADOW_EMIT_GO=false`, ingest `shadow_go_port` nacks gone, CPACK
  decoding, line producing. **G1 done. G4 is the remaining blocker for OEE data.**
- Residual noise: worker still runs `shadow_go_port` BACKGROUND rollup jobs (G3, WARN
  only). Debug tap was added + REMOVED from the box (clean).

## Official bundle — regeneration guide (2026-08-07)

The CPACK edge bundle is now **generatable from source with zero hand-patching** —
every F0–F6 fix is baked in by the generator, F2 comes from the live DB descriptor.

**Regenerate:**
```
gh workflow run generate-client-bundle.yml --ref staging \
  -f client=cpack -f target=production -f edge_model=nodered -f bundle_image=true
# then: gh run download <run-id> -D <dir>   → cpack-edge-bundle/
```
- Reads the LIVE descriptor from `client_descriptors` (prod DB) via #738/#744; committed
  `docs/clients/edge-deployment/cpack/cpack.descriptor.yaml` is the fallback.
- Verified bundle (run 31144455202): F0 `.env.example` ✅, F1 contrib install ✅,
  F2 `uplink_broker: ssl://ingest.prod.packiot.app:8883` ✅, F3 concrete key ✅,
  F4 `X-Ingest-Key` ✅, F5 rawtag envelope ✅, F6 suffix strip ✅, 10 `PLC_HOST_*` lines.

**To re-deploy the box** (makes it a persisted/regenerable artifact, retiring the
hand-patches): drop the bundle on the box, `load-image.sh`, fill the 10 `PLC_HOST_*`
in `.env` from the manifest below, set `AGENT_INGEST_API_KEY`, `docker compose up -d`.

### CPACK PLC hosts manifest (real factory IPs)
The descriptor `host_ref`s are `secret://packiot/production/cpack/<slug>-host` (contract:
never literal in the descriptor). The real IPs live on the box `.env` + here. Ideally
→ Secrets Manager `packiot/production/cpack/<slug>-host` (turnkey F9).

| Endpoint (`PLC_HOST_<NAME>`) | Host | Protocol |
|---|---|---|
| `PLC_HOST_PLC_L6` | `10.135.1.128:502` | modbus |
| `PLC_HOST_S7_115` | `10.135.16.115` | s7 |
| `PLC_HOST_S7_116` | `10.135.16.116` | s7 |
| `PLC_HOST_S7_L5` | `10.135.16.117` | s7 |
| `PLC_HOST_S7_S8` | `10.135.16.26` | s7 |
| `PLC_HOST_PLC_FLEXO` | `10.135.16.123` | s7 |
| `PLC_HOST_S7_L10` | `10.135.16.124` | s7 |
| `PLC_HOST_PLC_L4` | `10.135.1.126` | s7 |
| `PLC_HOST_PLC_L3` | `10.135.16.127` | s7 |
| `PLC_HOST_SLEEVES` | `10.135.16.101` | s7 |
| `OPC_UA_L9_FLEXO` | `opc.tcp://10.135.6.169:4840` | opcua |

### CPACK counters-only rated speeds (`equipments.production_speed`, parts/min)
Drive `COUNTERS_ONLY_IDEAL_RATES` (G4). All CPACK counter-equipments have
`ideal_speed=NULL`; the rate lives in `production_speed`.
`CER400=50 · BREYER2=100 · POLYTYPE1=80 · PTH80S=60 · L3/*=140 · L4/*=147 · L5/*=147`
(18 registered counter-equipments; L10/L6/SLEEVE/L3-BREYER produce but are unregistered
in `packml_register` — G5, so they don't emit yet).

### CPACK descriptor state (prod DB `client_descriptors`)
- `status = draft`; `agent.uplink_broker = ssl://ingest.prod.packiot.app:8883`;
  11 `plc.endpoints` with `secret://` host_refs; ~20 count_indices still `inferred`
  (works in draft; blocks `--cutover`). Onboarding CAPTURE (P2b observe) not yet run on
  new-prod (`capture_observations` table absent there).
