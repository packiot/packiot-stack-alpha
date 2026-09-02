# Edge & Data Ingestion

A Packiot factory turns **absolute PLC totalizer readings** into OEE numbers. The edge
path is the first half: get a raw tag onto the wire, across the factory WAN, into the
cloud, decoded and normalized. The governing idea (ADR-0042 + ADR-0045) is a
**rate-of-change × customization seam**.

## Mental model — three tiers

| Tier | Component | Owns | Changes |
|------|-----------|------|---------|
| **1 — connectivity** | Node-RED (stock `nodered/node-red:4.0`) | messy per-client PLC I/O; emits *raw suffix tags* as plain JSON | weekly |
| **2 — transmission** | Go `sparkplug-agent` | the entire SparkPlug B session: alias/NBIRTH/NDATA/NDEATH, seq, store-and-forward, mTLS uplink | never |
| **cloud — decode** | Go `edge-transformer` | decode SparkPlug, resolve aliases, run Calc, publish to RabbitMQ | never |

Two corrections newcomers get wrong:
1. The native Go readers (`s7-reader`/`modbus-reader`/`opcua-reader`) are **self-contained
   SparkPlug producers** publishing straight to MQTT — they do **not** POST to the
   agent's `:9104`. That HTTP tee path is fed by a Node-RED/HTTP tee speaking plain JSON.
2. `edge-transformer` **publishes to RabbitMQ** (`exchange oee`, key `sparkplug.data`) and
   does **not** write `equipment_values` — `oeecloud-worker` does, one hop downstream.

## The hop table

| Hop | Where | Protocol / Port |
|-----|-------|-----------------|
| PLC | factory floor | S7 / Modbus TCP / OPC-UA / native SparkPlug |
| Tier-1 connectivity | Node-RED | reads fieldbus; tees raw suffix tags |
| tee → agent | Node-RED `http request` | `POST http://sparkplug-agent:9104/v1/tags`, header `X-Ingest-Key` |
| Tier-2 agent | `sparkplug-agent` | ingest `:9104`, health `:9103`, onboard `:9105` |
| uplink | agent → cloud | **SparkPlug B over mTLS**, `ssl://…:8883`, CN-scoped |
| cloud broker | mosquitto | MQTT (retains NBIRTHs) |
| decode | `edge-transformer` | subscribes `spBv1.0/#` → decode → alias-resolve → Calc |
| normalize → bus | → RabbitMQ | exchange `oee`, key `sparkplug.data` |
| DB write | `oeecloud-worker` | INSERT `equipment_values` + OEE aggregates |

## Agent internals (`services/edge-transformer/cmd/sparkplug-agent/main.go`)

Pipeline: `rawmqtt → rawtag.Decode → tagstore.Apply (RBE)`; per-tick `DrainDirty →
session.BuildNDATA → encode → outbox.Enqueue`; uplink `onConnect → rebirth-then-drain`.

- **The rawtag wire contract** (`internal/agent/rawtag/rawtag.go`): Tier-1 emits **tag
  suffixes only** (`/Status/MachSpeed`), plus a `param` int for the ADR-0044 exception.
  The agent prepends the `packml_topic` prefix.
- **Ports**: `:9103` `/healthz`+`/metrics`, `:9104` `POST /v1/tags` (auth `X-Ingest-Key`,
  constant-time compare, fail-closed), `:9105` onboard-generate, `:8883` mTLS uplink
  (`ssl://` scheme arms TLS; a partial cert set errors rather than downgrading).
- **Alias allocation** (`aliasmap.go`): first-seen monotonic; a brand-new tag forces a
  **rebirth** before its NDATA (freezes the alias at the cloud first). Retained NBIRTH +
  `OnSeqGap`/`ErrNoBirth`→NCMD are the self-healing machinery.
- **Report-by-exception** (`tagstore.go`): a tag is dirty only when value/quality changed;
  no changes ⇒ no NDATA that tick.
- **Health**: any degraded component ⇒ HTTP **503** with `degraded_components[]` — never
  silent-degrade (ADR-0011). *(On a severed sandbox, "no raw tags received" is the honest
  degraded reason — up but no data.)*

## Cloud decode (`cmd/edge-transformer/main.go`)

- Subscribes to `spBv1.0/#` — **not** `spBv1.0/+/+/+/+` (which silently drops 4-segment
  node-level NBIRTH/NDATA; a real staging bug).
- **Alias resolution** (`internal/sparkplug/aliastable.go`): NBIRTH rebuilds the
  per-publisher `alias→{name,datatype}` table; NDATA substitutes the name; NDEATH deletes
  it. `ErrNoBirth`/`ErrUnknownAlias`/seq-gap all fire a Rebirth NCMD back to the edge.
- **Calc** (`internal/transforms/calc_production_counters/calc.go`): a Go port of the
  Node-RED "Calc Production Counters" subflow — turns absolute totalizers into per-event
  increments (`gross = net + scrap`), with a SETUP guard, glitch guard, and Phase-9 line
  aggregation.

## Config-as-data / the descriptor (ADR-0045)

**One CS-Admin-authored client descriptor per tenant is the SSoT; everything else is
generated.** The schema is Go (`internal/agent/clientdescriptor/clientdescriptor.go`),
worked examples in `docs/clients/{cpack,bispharma}.descriptor.yaml`.

`onboard-gen` (`cmd/onboard-gen/`) emits four artifacts, all pure functions of the
validated descriptor:

| Artifact | What |
|----------|------|
| `<tenant>-profile.yaml` | normalization SSoT (count-index overrides per member) |
| `<tenant>-register.sql` | one `INSERT INTO packml_register (…, active=true) ON CONFLICT (packml_topic) DO NOTHING` per equipment |
| `<tenant>-agent.yaml` | agent config; `raw_tag_map` synthesized from the profile |
| `<tenant>-tee-node.json` | Node-RED tee snippet; reads the ingest key from env, never bakes a secret |

Normalization quirks are absorbed **stack-side** in the agent profile (ADR-0045 §2.3
Option B): `prefix_fixups` (`C-PACK/`→`CPACK/`), `metric_aliases`
(`Status/CurMachSpeed`→`Status/MachSpeed`), `parameter_aliases`. `count_index` modes:
`equipment_id` (id substitutes for `{idx}`) vs `explicit` (every member must pin an index).

## Edge deployment

- **Bundle-artifact (default):** a GitHub Action builds a per-client bundle (compose +
  generated artifacts + a `CN=<tenant>` mTLS cert + a `docker save`d image) as an
  artifact; a CS engineer drops it on the box and `docker compose up -d`. No runner at
  the client.
- **Box Ops today** = `edge-api` fires GitHub Actions via `workflow_dispatch`
  (`usecases/edge-bundle/`), plus a best-effort `:9103/healthz` probe
  (`usecases/plc-status/agent-health`). **AWS-SSM Box Ops is ADR-0049 design-of-record**,
  proven on the sandbox but not the shipped default control surface.
- **Client-box topology** (`docs/clients/edge-deployment/compose.edge.yml`): `nodered` +
  `mosquitto` (loopback) + `sparkplug-agent`. The **sandbox CPACK replica**
  (`docs/clients/sandbox-edge/`) mirrors this with the data path severed at 4 layers +
  a namespace cut (loopback uplink, `CN=sbxcpack` throwaway CA, no PLC, no register DB).

## Key concepts (see also [Concepts](08-concepts.md))

- **SparkPlug aliases/BIRTH** — DATA references a metric by a `uint64` alias bound only in
  the retained NBIRTH; a missed BIRTH makes every NDATA undecodable until a rebirth.
- **count-index ≠ id_equipment (#601)** — the count-index is an arbitrary PLC channel
  (`.../ProdProcessedCount/<idx>/Unit`), not derivable from any table; conflating it with
  `id_equipment` synthesizes tags the PLC never sends → 0 counts. Capture it live.

## War stories

| Story | Root cause | Guard |
|-------|-----------|-------|
| First-boot totalizer spike (`b60804c`) | `incr = cur − prev` discarded the "found" bool → first-obs dumped the whole totalizer | seed baseline + emit 0 on first-obs; uint16-rollover discrimination; worker clamp backstop |
| Alias/BIRTH loss (CPACK zero line counts) | sparse lines idle at restart never re-birthed → NDATA undecodable | rebirth on brand-new tag; retained NBIRTH; NCMD on `ErrNoBirth`/seq-gap |
| `spBv1.0/+/+/+/+` drops node topics | `+` matches one segment; SparkPlug has 4- and 5-seg topics | subscribe `spBv1.0/#` |
| CPACK bundle F0–F6 | 7 generator bugs, one per hop (env-KEY non-interpolation, wrong envelope shape → 200 OK but 0 tags, etc.) | all fixed; regenerates hands-free |
