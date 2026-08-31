# Edge & Data Ingestion

A Packiot factory turns **absolute PLC totalizer readings** into OEE numbers. The edge
path is the first half: get a raw tag onto the wire, across the factory WAN, into the
cloud, decoded and normalized. The governing idea (ADR-0042 + ADR-0045) is a
**rate-of-change × customization seam** — plus the operating rule that **a client is
data, not infrastructure** (ADR-0047): onboarding a factory adds a config file, never a
new container/nginx/DNS/SG.

> The agent + decoder binaries live in the **`services/sparkplug-decoder/`** service
> tree (the renamed edge-transformer service): it builds both the cloud `edge-transformer`
> decode binary (`cmd/edge-transformer/`) and the edge `sparkplug-agent` binary
> (`cmd/sparkplug-agent/`). File paths below cite that tree.

## Mental model — three tiers

| Tier | Component | Owns | Changes |
|------|-----------|------|---------|
| **1 — connectivity** | Node-RED (stock `nodered/node-red:4.0`) or a thin native reader | messy per-client PLC I/O; emits *raw suffix tags* as plain JSON | weekly |
| **2 — transmission** | Go `sparkplug-agent` | the entire SparkPlug B session: alias/NBIRTH/NDATA/NDEATH, seq, store-and-forward, mTLS uplink | never |
| **cloud — decode** | Go `edge-transformer` | decode SparkPlug, resolve aliases, run Calc, publish to RabbitMQ | never |

Two corrections newcomers get wrong:
1. The native Go readers (`s7-reader`/`modbus-reader`/`opcua-reader`) are **self-contained
   SparkPlug producers** publishing straight to MQTT — they do **not** POST to the
   agent's `:9104`. That HTTP tee path is fed by a Node-RED/HTTP tee (or a thin reader)
   speaking the plain-JSON **rawtag** envelope.
2. `edge-transformer` **publishes to RabbitMQ** (`exchange oee`, key `sparkplug.data`) and
   does **not** write `equipment_values` — `oeecloud-worker` (the `stream-engine`
   container) does, one hop downstream.

## Shared multi-tenant ingest (the current model)

The cloud `sparkplug-agent` is **multi-tenant**: **one process serves N tenants**, each an
isolated pipeline keyed by the SparkPlug `group_id`. There is **one shared, tenant-agnostic
front-door** — `ingest.<env>.packiot.app:8449` — rather than a per-tenant vhost/container.
Onboarding a client is a **generated tenant config file dropped into the tenants dir**, not
new infra.

### The one front-door

| Piece | Value | Source |
|-------|-------|--------|
| Public ingress | `https://ingest.<env>.packiot.app:8449/v1/tags` (TLS on 8449) | `terraform/staging/dns.tf` (`shared_ingest`), `security_groups.tf` (ingress 8449, **per-box egress /32**) |
| nginx reverse-proxy | `8449 → http://172.18.0.44:9104/v1/tags` | `terraform/staging/user_data/nginx_setup.sh` (shared multi-tenant front-door block) |
| Container | `sparkplug-agent-shared` (compose profile `shared-tee`) | `compose.staging.yml` |
| Auth | shared `X-Ingest-Key` header (all tenants) | agent (`AGENT_INGEST_API_KEY`) |

Tenant isolation is enforced by **agent group-routing + the per-box SG /32** — *not* by the
key (the key is shared across tenants). The front-door is tenant-agnostic: it forwards every
`/v1/tags` body to the one shared agent, which routes on the envelope's `group`.

### Agent modes (boot-time, mutually exclusive)

`cmd/sparkplug-agent/main.go` picks one of two modes at boot:

| Mode | Trigger | Behaviour |
|------|---------|-----------|
| **Single-file** | `AGENT_CONFIG=/etc/packiot/agent.yaml` (or `--config <path>`) | one pipeline; the byte-identical legacy behaviour. **Only mode** that supports the register-cutover flip (ADR-0045 P2a) and the live-capture observe posture (P2b) — both need per-tenant DB machinery. |
| **Multi-tenant** | `AGENT_TENANTS_DIR=/etc/packiot/tenants` (+ `AGENT_OUTBOX_DIR`) | every `*.yaml`/`*.yml` in the dir becomes one **fully-isolated** pipeline keyed by `sparkplug.group_id`. **Static-map only** (no register cutover / capture). |

Multi-tenant isolation is real, not cosmetic (`buildTenantPipelines`):

- **Per-group alias space** — each pipeline gets its own `aliasmap`; alias 7 means different
  metrics in different tenants. Sharing one map would corrupt the cloud's per-group
  `alias→name` table.
- **Per-tenant outbox** — one store-and-forward file per group at
  `AGENT_OUTBOX_DIR/<group>.db` (default `/var/lib/edge-transformer/outbox`), preserving the
  single-drainer invariant while keeping tenants independent.
- **Startup fails** if two tenant configs share a `group_id` **or** an `edge_node_id` (both
  ambiguous / flapping).
- **Blast-radius isolation** — each tenant's uplink is registered as a **readiness**
  (non-critical) health component. One tenant's broker blip surfaces in `/healthz`
  `degraded_components[]` but **never flips container liveness** and bounces the process
  (which would take every co-tenant, including CPACK, down with it). Liveness in multi mode =
  "process up + serving `/healthz` + routing ingest".

### Routing (`internal/agent/httpingest/httpingest.go`, `NewRouter`)

`POST /v1/tags` dispatches on the envelope's declared **`group`** (also accepted as
`group_id` or `tenant`) to the matching tenant Sink. In multi-tenant mode the group is
**mandatory**: a **missing** group or a group with **no matching route** is refused **403**
(`rejected_scope`) — there is no default/fallback pipeline, so an unrouteable body is
rejected rather than silently dropped. (Single-file mode keeps the legacy scope semantics:
an absent group is accepted; a group that isn't ours → 403.)

### Adding a client = a config file

`sparkplug-agent-shared` mounts `./docs/clients/tenants → /etc/packiot/tenants:ro`. A new
client is:

1. `onboard-gen` emits the tenant's `<tenant>-agent.yaml` (its `raw_tag_map` synthesized
   from the descriptor).
2. Drop that file into the tenants dir.
3. Restart the shared agent.

**No new container, nginx server block, DNS record, or SG rule.** The older one-agent-per-
client pattern (`sparkplug-agent-cpack`, profile `cpack-tee`, its own
`cpack-ingest.<env>:8447` front-door → `172.18.0.38:9104`) still runs for CPACK today; CPACK
migrates onto the shared agent once the shared path is proven.

## The rawtag wire contract (the envelope)

Tier-1 (Node-RED tee, or a thin reader) POSTs this **rawtag** JSON to `/v1/tags`
(`internal/agent/rawtag/rawtag.go`, `internal/agent/httpingest`):

```json
{
  "group": "BISPHARMASTAGING",
  "endpoint": "<device/host>",
  "scan_ts": 1699999999,
  "tags": [
    { "metric": "/Status/MachSpeed", "value": 12.3, "q": true, "long": false, "ts": 0, "param": 0 }
  ]
}
```

| Field | Meaning |
|-------|---------|
| `group` / `group_id` / `tenant` | the SparkPlug group_id — the router key; **mandatory** in multi-tenant mode |
| `endpoint` | connectivity-plane device/host the reading came from |
| `scan_ts` | scan timestamp (unix); per-tag `ts` overrides it |
| `tags[].metric` | the tag **suffix** only (e.g. `/Status/MachSpeed`); the agent prepends the tenant's `packml_topic` prefix |
| `tags[].value` | JSON scalar (number / bool / string) |
| `tags[].q` | quality; absent ⇒ good |
| `tags[].long` | int64 type hint |
| `tags[].param` | PackML parameter id for the ADR-0044 bare-`Parameter` exception; 0 ⇒ absent |

!!! danger "The old tee shape is a deprecated shim — the agent drops it silently"
    The legacy generated tee node emitted `{timestamp, gateway, metrics[]}` — that is the
    **ingest-shim** contract, **not** what the agent expects. Posting it returns **202 with
    0 tags accepted** (a silent drop). Use the rawtag envelope above; don't copy the legacy
    tee node verbatim.

## The hop table

| Hop | Where | Protocol / Port |
|-----|-------|-----------------|
| PLC | factory floor | S7 / Modbus TCP / OPC-UA / native SparkPlug |
| Tier-1 connectivity | Node-RED or thin reader | reads fieldbus; emits raw suffix tags |
| tee/reader → front-door | HTTP | `POST https://ingest.<env>.packiot.app:8449/v1/tags`, header `X-Ingest-Key`, rawtag envelope |
| shared front-door | nginx | TLS `:8449` → `172.18.0.44:9104/v1/tags` (`sparkplug-agent-shared`) |
| Tier-2 agent | `sparkplug-agent` | ingest `:9104` (`POST /v1/tags`), health `:9103`, onboard `:9105`; routes by envelope `group` |
| uplink | agent → cloud | **SparkPlug B over mTLS**, `ssl://…:8883`, CN-scoped per tenant |
| cloud broker | mosquitto | MQTT (retains NBIRTHs) |
| decode | `edge-transformer` | subscribes `spBv1.0/#` → decode → alias-resolve → Calc |
| normalize → bus | → RabbitMQ | exchange `oee`, key `sparkplug.data` |
| DB write | `oeecloud-worker` (`stream-engine`) | INSERT `equipment_values` + OEE aggregates |

> The full ADR-0042 topology (connectivity Node-RED → loopback MQTT → local agent on the
> box) still exists. In the shared model the box needs only a **reader with WAN reach to the
> shared front-door**; the agent lives in the cloud, not on the box.

## Agent internals (`cmd/sparkplug-agent/main.go`)

Per pipeline: `rawmqtt → rawtag.Decode → tagstore.Apply (RBE)`; per-tick `DrainDirty →
session.BuildNDATA → encode → outbox.Enqueue`; uplink `onConnect → rebirth-then-drain`.

- **Ports**: `:9103` `/healthz`+`/metrics`, `:9104` `POST /v1/tags` (auth `X-Ingest-Key`,
  constant-time compare, **fail-closed** — enabled-but-keyless refuses to serve), `:9105`
  onboard-generate, `:8883` mTLS uplink (`ssl://` scheme arms TLS; a partial cert set errors
  rather than downgrading to plaintext).
- **Alias allocation** (`internal/agent/aliasmap`): first-seen monotonic **per group**; a
  brand-new tag forces a **rebirth** before its NDATA (freezes the alias at the cloud first).
  Retained NBIRTH + `OnSeqGap`/`ErrNoBirth`→NCMD are the self-healing machinery.
- **Report-by-exception** (`internal/agent/tagstore`): a tag is dirty only when value/quality
  changed; no changes ⇒ no NDATA that tick.
- **Health**: any degraded *critical* component ⇒ HTTP **503** with `degraded_components[]` —
  never silent-degrade (ADR-0011). Per-tenant uplinks are readiness-only in multi mode (see
  blast-radius isolation above). *(On a severed sandbox, "no raw tags received" is the honest
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

## Config-as-data / the descriptor (ADR-0045 / ADR-0047)

**One CS-Admin-authored client descriptor per tenant is the SSoT; everything else is
generated.** The schema is Go (`internal/agent/clientdescriptor/clientdescriptor.go`),
worked examples in `docs/clients/{cpack,bispharma}.descriptor.yaml`.

`onboard-gen` (`cmd/onboard-gen/`) emits four artifacts, all pure functions of the
validated descriptor:

| Artifact | What |
|----------|------|
| `<tenant>-profile.yaml` | normalization SSoT (count-index overrides per member) |
| `<tenant>-register.sql` | `INSERT INTO packml_register (…, active=true) … ON CONFLICT (packml_topic) WHERE active DO NOTHING` per equipment, **then a `UPDATE … SET id_site, id_area` backfill from `equipments`** |
| `<tenant>-agent.yaml` | agent config; `raw_tag_map` synthesized from the profile — **this is the tenant file dropped into the shared agent's tenants dir** |
| `<tenant>-tee-node.json` | Node-RED tee snippet; reads the ingest key from env, never bakes a secret |

!!! warning "The register must carry id_site / id_area or counts vanish"
    `packml_register` rows need `id_site`/`id_area` populated — the stream-engine registry
    uses them to place a row into `equipment_values`. A NULL site/area makes the topic read
    as **"topic not registered"** and the tenant's counts are **silently dropped** (verified
    on staging: bispharma decoded fine but never wrote until the backfill). They aren't in
    the descriptor (each equipment belongs to exactly one site/area, so they're derivable) —
    the generated register SQL backfills them from `equipments` at apply time (idempotent +
    self-healing).

Normalization quirks are absorbed **stack-side** in the agent profile (ADR-0045 §2.3
Option B): `prefix_fixups` (`C-PACK/`→`CPACK/`), `metric_aliases`
(`Status/CurMachSpeed`→`Status/MachSpeed`), `parameter_aliases`. `count_index` modes:
`equipment_id` (id substitutes for `{idx}`) vs `explicit` (every member must pin an index).

## Edge deployment

- **Bundle-artifact (default):** a GitHub Action builds a per-client bundle (compose +
  generated artifacts + a `CN=<tenant>` mTLS cert + a `docker save`d image) as an
  artifact; a CS engineer drops it on the box and `docker compose up -d`. No runner at
  the client. In the shared model the box side collapses to a reader + WAN reach to the
  shared front-door.
- **Box Ops today** = `edge-api` fires GitHub Actions via `workflow_dispatch`
  (`usecases/edge-bundle/`), plus a best-effort `:9103/healthz` probe
  (`usecases/plc-status/agent-health`). **AWS-SSM Box Ops is ADR-0049 design-of-record**,
  proven on the sandbox but not the shipped default control surface.
- **Client-box topology** (`docs/clients/edge-deployment/compose.edge.yml`): `nodered` +
  `mosquitto` (loopback) + `sparkplug-agent` — the full on-box topology. The **sandbox CPACK
  replica** (`docs/clients/sandbox-edge/`) mirrors this with the data path severed at 4
  layers + a namespace cut (loopback uplink, `CN=sbxcpack` throwaway CA, no PLC, no register
  DB).

## Key concepts (see also [Concepts](08-concepts.md))

- **Shared multi-tenant ingest** — one agent process, one `:8449` front-door, N tenants
  routed by SparkPlug `group_id`; a client is a config file, not infra.
- **SparkPlug aliases/BIRTH** — DATA references a metric by a `uint64` alias bound only in
  the retained NBIRTH; a missed BIRTH makes every NDATA undecodable until a rebirth.
- **count-index ≠ id_equipment (#601)** — the count-index is an arbitrary PLC channel
  (`.../ProdProcessedCount/<idx>/Unit`), not derivable from any table; conflating it with
  `id_equipment` synthesizes tags the PLC never sends → 0 counts. Capture it live.

## War stories

| Story | Root cause | Guard |
|-------|-----------|-------|
| Tenant decodes but never writes (bispharma) | `packml_register` rows had NULL `id_site`/`id_area` → registry reads the topic as unregistered → counts silently dropped | register SQL backfills `id_site`/`id_area` from `equipments` |
| First-boot totalizer spike (`b60804c`) | `incr = cur − prev` discarded the "found" bool → first-obs dumped the whole totalizer | seed baseline + emit 0 on first-obs; uint16-rollover discrimination; worker clamp backstop |
| Alias/BIRTH loss (CPACK zero line counts) | sparse lines idle at restart never re-birthed → NDATA undecodable | rebirth on brand-new tag; retained NBIRTH; NCMD on `ErrNoBirth`/seq-gap; `AGENT_BIRTH_ALL_MAPPED` |
| `spBv1.0/+/+/+/+` drops node topics | `+` matches one segment; SparkPlug has 4- and 5-seg topics | subscribe `spBv1.0/#` |
| Legacy tee shape 202-but-0-tags | `{timestamp,gateway,metrics}` is the ingest-shim shape, not the rawtag envelope | POST `{group,endpoint,scan_ts,tags[]}` |
