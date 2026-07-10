# Validity verdict — does Packiot's refactored stack faithfully replicate CPACK's real Node-RED flow?

_Assessed 2026-07-10 against `packiot-stack-alpha` @ `staging`. Read-only audit; every claim cites a file/mechanism in the repo._

> **Why this doc exists:** a point-in-time audit reconciling CPACK's real
> production Node-RED flow (473 nodes, S7+Modbus+OPC-UA ingest, custom operator
> SPA, Firebase auth) against the refactored Go stack — to answer "is the
> refactor valid for CPACK?" ahead of THE FLIP (#28). Its per-dimension gaps
> feed the flip checklist. The companion is
> [`incoplast-migration-assessment.md`](incoplast-migration-assessment.md)
> (the Node-RED-*elimination* client); CPACK is the Node-RED-*kept* client.

---

## Executive verdict

**VALID for CPACK today — with one framing correction that dissolves the biggest apparent gap.**

The task frames the refactor as *requiring* Go protocol readers to "replace CPACK's in-flow SparkPlug synthesis." **That premise is only true for the full Node-RED-elimination endgame, and the roadmap explicitly does NOT require it for CPACK.** The architecture (ADR-0009) deliberately *keeps* Node-RED as the per-factory protocol / SparkPlug-synthesis layer ("Node-RED stays... it owns PLC protocol nodes — OPC-UA Items, SparkPlug clients, Modbus/S7 readers — Node-RED's ecosystem here is the best on the market and worth keeping"). The endgame roadmap's production-migration phase then states verbatim: *"Incoplast-class prerequisites (ADR-0019): edge command channel + S7 rack/slot + edge-operator mode... **CPACK-class factories are unaffected**"* (`docs/overview/07-endgame-roadmap.md` F2b).

So the correct model for **CPACK**:

```
CPACK Node-RED (KEEPS OPC-UA/Modbus/S7 reads → synthesizes SparkPlug B)
   │  MQTT spBv1.0/#  (and legacy PubSub, retired at F4)
   ▼
edge-transformer (Go)  ── consumes SparkPlug unchanged, decode→transform→AMQP
   ▼
oeecloud-worker (Go)   ── routes by source_type, computes OEE, writes DB
operator-adapter (Go)  ── operator PO/downtime writes → edge-api
refdata-api (Go)       ── operator + front4 reads (replaces Hasura)
```

Under this model the refactor is a **faithful, largely complete** replica of CPACK's *cloud-consuming, operator-write, and operator-read* surfaces, and it runs on staging today. The Go protocol readers (S7 done, OPC-UA/Modbus absent) belong to the *optional* future where Node-RED is deleted at a factory — an Incoplast-class concern, S7-first. Treating that as a CPACK blocker is a category error.

**What would actually block CPACK** (net of the framing correction): nothing structural today. The residual items are (a) a few PackML params the compute path still skips, (b) the PLC-command return path being built-but-unvalidated, and (c) per-factory Firebase→`/session` cutover being Phase-F work. All are RISK/partial-GAP, none is a wall.

---

## Per-dimension table

| Dimension | CPACK mechanism | Refactor coverage | Verdict | Evidence |
|---|---|---|---|---|
| **1. Ingest** | SparkPlug synthesized in-flow from S7 (9)/Modbus (4)/OPC-UA (2); egressed to PubSub + AMQP | `edge-transformer/internal/mqtt/subscriber.go` subscribes `spBv1.0/#` and consumes CPACK's synthesized SparkPlug unchanged. Node-RED keeps doing the protocol reads. **Go readers exist for S7 only** (`internal/s7/`, `cmd/s7-reader`), built as a *SparkPlug producer* for Incoplast. **No OPC-UA reader, no Modbus reader.** | **VALID today** (Node-RED synthesizes); **GAP** only for NR-elimination endgame | `internal/mqtt/subscriber.go:50`; `internal/s7/`; `docs/adr/reference/designs/0019-G4-s7-read-adapter.md`; ADR-0009 §Decision |
| **2. SparkPlug params** | 30700-30772 config/counters + 30800-30862 PO/status | Counters 30710/30761/30763/30770/30772 → `transforms/calc_production_counters` ✓. 30701 ideal-speed ✓, 30750/30758 thresholds ✓, 30702 lead-machine ✓. PO control 30800-30805/30810-30814/30820 → `pocontrol/*` (wired via `handlers/sparkplug.go`) ✓. 30850 analogs ✓. Setup 30861/30862/30880 ✓. **Skipped/missing: 30700 line-order (explicitly logged-and-skipped), 30751 min-threshold-time (absent), 30860 status (absent).** | **Mostly VALID; 3 named GAPS** | `internal/writers/po_parameter.go:19-76` (30700 skip); `pocontrol/decide.go`,`events_justify.go`,`setup_userlog.go`; grep: 30751/30860 = MISSING |
| **3. Operator writes** | start/change/replace/create/setup PO; justify/split/manual-add/edit downtime; scrap; production counts; CSV export | `operator-adapter` covers PO create-and-start, stop, setup, replace, change-status, change-time, and downtime create/edit (30810-30814) → edge-api `production-orders/*`, `downtimes/*`. **Scrap = data-path counters by design** (edge-api has no scrap endpoint; correction rides inside stop/setup bodies) — VALID. **Production counts = data-path** — VALID. **CSV export = a read/export (front4/refdata concern), not an operator write.** **Split-events: no adapter route / no handler found → GAP.** PLC-direction control (start/stop→PLC, config, status via `Parameter[]`) → **command channel is implemented** (`edge-transformer/internal/command/{consumer,executor,dcmd,mqttpub}.go`) but **design-status, validates post-flip** against a real machine. | **VALID for DB-write direction; RISK on split-events + unvalidated PLC-command path** | `operator-adapter/internal/adapter/server.go:67-75`; `operator-adapter/README.md` (scrap §); `edge-transformer/internal/command/`; `docs/adr/reference/designs/0019-C1-edge-command-channel.md` (Status: design) |
| **4. Operator reads** | Hasura GraphQL: POs, events, reasons, shifts, users, language packs, machines | `refdata-api` fixed routes: `/v1/operator-po-list`, `operator-po-details`, `operator-entities`, `entities-per-user-role`, `language-packs`, `downtime-reasons`, `shift-hours[-by-enterprise]`, `events-timeline`, `pending-downtime`, `day-week-begin`; plus dataset groups oee / downtimes / machine-speed / targets / users. C1 audit: **refdata covers 10/10 staging Hasura root fields.** | **VALID** | `refdata-api/cmd/refdata-api/main.go:80-90`, `datasets.go`; `07-endgame-roadmap.md` C1 |
| **5. Egress** | Google PubSub + AMQP | **No PubSub in `services/`** (only doc references remain). edge-transformer egresses via AMQP (`internal/amqp`, `shadowpub`, `outbox`). RabbitMQ is the sole data-plane bus. PubSub retirement is scheduled at **F4 (prod legacy decommission)** — CPACK's own NR still dual-egresses (PubSub+AMQP) until its prod cutover. | **VALID on refactor side; PubSub live in prod legacy until F4** | grep `pubsub` → only `oeecloud-worker/docs/*.md`; `internal/amqp/`,`shadowpub/`; `07-endgame-roadmap.md:169` F4 |
| **6. Auth** | Firebase (edge) | Replaced by edge-api `/session` (bcrypt, **already built**, ADR-0018 wave 2) + **Authentik SSO** (healthy on staging, fronting operator SPA). refdata handles read auth. Per-factory Firebase retirement is C3 / Phase-F work — not yet done for real CPACK. Erratum: leaked Firebase key needs rotation. | **VALID architecture, built; per-factory cutover pending (RISK)** | `docs/adr/reference/designs/0019-C3-edge-operator-spa.md:50-51`; `06-state-and-continuation.md:27,41` (Authentik healthy); ADR-0009 Erratum Phase 0.5 (key rotation) |

---

## Prioritized gap list

**P0 — real blockers for "CPACK entirely on the new stack": none.** CPACK keeps its Node-RED protocol layer; the consuming stack is complete and live on staging. The items below are the honest residuals.

**P1 — compute-path parameter gaps (data-fidelity risk, fixable in isolation)**
1. **30700 line-order** — explicitly logged-and-skipped in `writers/po_parameter.go:64-67` ("needs packml_register lookup"). If CPACK emits it, line-order config is silently dropped.
2. **30751 min-threshold-time** — absent from both workers. Pairs with 30750 (present); a half-ported threshold pair is a latent CPAC-algorithm correctness bug.
3. **30860 status** — absent (30861/30862/30863 present). Confirm CPACK doesn't rely on it before flip.

**P2 — operator-action completeness**
4. **Split-events** — no operator-adapter route and no handler found. CPACK's UI splits events; confirm whether this maps to edit-manual-event (30812-30814) or is genuinely uncovered.
5. **PLC command channel (C1)** — implemented in `edge-transformer/internal/command/` but **design-status / unvalidated against a real PLC**. This is the return path CPACK's `Send_Parameter` / `change PO PackML` uses. Blocks nothing on the read/DB-write side, but PLC write-back parity is unproven until a machine (or plc-sim) receives a DCMD.

**P3 — endgame-only, NOT CPACK blockers (would matter only if deleting CPACK's Node-RED)**
6. **OPC-UA Go reader** — absent. `cpack.example.yaml` declares CPACK as `protocol: opcua` (B&R/Acopos). The G4 note lists `gopcua/opcua` as a *fallback*, unbuilt. Required only for full NR elimination at CPACK.
7. **Modbus Go reader** — absent entirely. Same caveat.

**P4 — migration hygiene**
8. **Firebase → `/session` per-factory cutover** — architecture built and blessed; the actual retirement of CPACK's Firebase is Phase-F/C3. Rotate the leaked Firebase key (ADR-0009 Erratum Phase 0.5) independently.
9. **GCP PubSub decommission** — F4; CPACK dual-egresses until its prod cutover.

---

## The one sentence a reviewer needs

The refactor **faithfully replicates everything CPACK's flow does *downstream of the SparkPlug boundary*** (compute, operator writes, operator reads, egress, auth) and runs it on staging today; it does **not** replicate CPACK's *upstream* protocol synthesis in Go — and by deliberate architectural decision (ADR-0009 + roadmap F2b) **it doesn't have to**, because CPACK-class factories keep Node-RED for exactly that. The only Go protocol reader that exists (S7) is an Incoplast-first stepping stone toward the *optional* Node-RED-elimination endgame, where OPC-UA and Modbus readers remain genuine gaps.
