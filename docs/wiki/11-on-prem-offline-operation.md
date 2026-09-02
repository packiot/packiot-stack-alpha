# On-Prem Offline Operation (the fat edge)

How a client's shop floor keeps seeing **live** production during an internet
outage. This is the **visibility half** of ADR-0053 ("B-minimal") — an *additive*
decode + dashboard stack that runs on the factory box **alongside** the existing
thin reader. It ships on `origin/staging`; the *durability half* (draining a
decoded stream to the cloud) remains **proposed** — see [Relation to ADR-0053](#relation-to-adr-0053).

> **Where this sits.** [Outage Resilience & Offline Operation](10-outage-resilience-and-offline.md)
> is the general picture: the reader disk-spool keeps the **counts**, the operator
> PWA queue keeps the **actions**, but *live reads* go dark offline (dashboards read
> cloud data after the message bus). This page is that missing piece — an on-box
> read-cache that keeps the **live numbers** on the floor's screen while the link
> is down. It is **opt-in per client**, not the default posture.

## The one-line model

The box already egresses **HTTPS only** (client firewalls block AMQP/8883 — the
reason the reader uploads over HTTPS at all). So we don't try to publish from the
box; we **tee a copy** of the raw tags into a *local* decode stack that writes a
**current-state cache**, and point a self-contained dashboard at it:

```
PLC ─raw tags─▶ packiot-edge-reader ─┬─▶ cloud shared-agent (HTTPS)   [PRIMARY — authoritative, unchanged]
                                     │
                                     └─▶ local sparkplug-agent :9104  [best-effort tee]
                                              │ SparkPlug B
                                              ▼
                                         mosquitto (local broker)
                                              │
                                              ▼
                                     edge-transformer  (LOCAL_DECODE_ONLY)
                                              │ UPSERT each decoded metric
                                              ▼
                                     localstate  (SQLite current-state)
                                              │ read
                                              ▼
                                     edge-dashboard :8080  ◀── the floor's browser
```

Two things make this **outage-immune by construction**:

1. The on-box transformer runs in **`LOCAL_DECODE_ONLY`** — it opens **zero cloud
   sockets**. It decodes *only* to feed the local cache. There is nothing for an
   outage to break.
2. The cloud is **not** fed from this stack. The reader's **primary tee** (reader →
   cloud shared-agent over HTTPS) plus the reader spool already carry and buffer
   this tenant's data to the cloud. **Cloud stays the system of record; the box
   gains local *visibility*, not a second write path.**

If the whole on-prem stack is down, the client is exactly where they are today: the
cloud path is untouched.

## What actually runs on the box

An additive compose file, `compose.onprem-edge.yml`, brings up four small
containers next to the reader (all `packiot-sparkplug-decoder:local`, one image):

| Container | Role | Notes |
|---|---|---|
| `onprem-mosquitto` | local SparkPlug broker | `eclipse-mosquitto:2`, loopback only |
| `onprem-agent` | local half of the reader tee | HTTP ingest on `127.0.0.1:9104`; republishes raw tags as a SparkPlug B session onto the *local* mosquitto. `AGENT_BIRTH_ALL_MAPPED=true` so a line idle at connect is still aliased the instant it first reports |
| `onprem-transformer` | decode → cache | `LOCAL_DECODE_ONLY=true`; `LOCAL_STATE_DB=…/current-state.db`; **no** cloud AMQP publisher, **no** outbox. `PHASE9_LINE_AGG_ENABLED` so line-metered tenants (bispharma) get line counts locally too |
| `onprem-dashboard` | the floor board | serves `:8080`, reads the same current-state volume, renders a per-machine LIVE/STALE view. Fully self-contained — no external assets, because there is no internet when it matters |

The agent's uplink target is `tcp://mosquitto:1883` — the **local** broker, not the
cloud. Usefully, the *cloud* shared-agent already publishes to *its* co-located
mosquitto, so the generated `agent.yaml` string is **byte-identical** to what the
box needs; no agent-config variant is required (ADR-0053 §9).

Citations: `compose.onprem-edge.yml`; `services/sparkplug-decoder/cmd/edge-transformer/main.go`
(the `LOCAL_DECODE_ONLY` gate ≈`:410`, the `LOCAL_STATE_DB` sink open ≈`:554`);
`services/sparkplug-decoder/cmd/edge-dashboard/main.go`.

## localstate vs. the outbox — two halves of outage tolerance

The single most important idea here is a **contrast** with the buffer ADR-0053's
durability half is built on. Same storage tech (pure-Go `modernc.org/sqlite`, WAL),
**opposite shape**:

| | **outbox** (`internal/outbox`, ADR-0011) | **localstate** (`internal/localstate`, ADR-0053) |
|---|---|---|
| Pattern | store-and-**forward** | store-and-**overwrite** |
| Purpose | data **durability** (nothing lost) | live **visibility** (the floor can still see the line) |
| Row lifecycle | append serialized messages; **DELETE on drain** | one **UPSERT** per `(tenant, source, metric)`; newest wins |
| Answers | *"what is still unsent?"* | *"what is the current count on machine X?"* |
| Drains to cloud? | yes (that's its whole job) | **never** — it's a read-cache |

Because localstate keys on the SparkPlug **source identity** (`GROUP/EDGE/DEVICE` +
metric), not `id_equipment`: on the box the decoder does **not** resolve
name → `id_equipment` (that resolution is cloud-side, via `packml_register`). The
dashboard maps source → a friendly machine name via the on-box descriptor. The tee
into localstate is **nil-guarded and best-effort** — a cache write can never block
or fail the decode path — so when `LOCAL_STATE_DB` is unset the transformer's
behavior is **byte-identical** to the cloud build.

> The mental hook: **outbox = "nothing lost," localstate = "still visible."** An
> outage needs both answers; these are the two data structures that give them.

## Turning it on — the onboarding toggle

On-prem offline operation is **opt-in per client**, surfaced in the CS-Admin
onboarding **"Connect the PLCs"** step as an **"Enable on-prem offline operation"**
toggle. Flipping it sets a single flag on the tenant's descriptor:
`client_descriptors.descriptor.onprem_offline = true`.

The edge-api contract behind the toggle:

- `GET /api/onboarding/onprem-offline` → `{ enabled }` (reads
  `descriptor.onprem_offline`; 404 when the tenant has no descriptor row yet).
- `POST /api/onboarding/onprem-offline` → merge-sets the flag in place (audit
  event `onboarding.onprem-offline`).

Citations: `edge-api` `src/usecases/onboarding/onprem-offline/onprem-offline.controller.ts`
(`@Controller('/api/onboarding/onprem-offline')`, `@Get`/`@Post`);
`onprem-offline.service.ts`; `src/data/DAO/client-descriptor/client-descriptor-dao.ts`
(`getOnpremOffline`).

**What the flag drives:**

1. **The reader tee.** When `onprem_offline=true`, the reader bundle appends a
   **second, best-effort** ingest target — the on-box local agent at
   `http://127.0.0.1:9104/v1/tags` — after the primary cloud target. `targets[0]`
   is always the authoritative cloud path; the local target is **never spooled or
   retried** (a down/absent local agent must not delay or drop the primary path).
   See `edge-api` `src/usecases/edge-ssm/shared/reader-bundle.ts`
   (`LOCAL_AGENT_INGEST_URL`, the `onpremOffline` bundle option, `ReaderTarget`
   mode `best_effort`).
2. **The Box-Ops deploy** brings `compose.onprem-edge.yml` up on the box (`up -d
   --build`), assembling the on-prem bundle from the existing generated
   `agent.yaml` + per-tenant `client.yaml` + a static compose file + a trivial
   `.env.onprem` (`TENANT`, `AGENT_INGEST_API_KEY`, `DASHBOARD_PORT`).

> **Shipped vs. in-flight.** The edge-api endpoint + descriptor flag + reader-tee
> gate + the whole on-box stack (`compose.onprem-edge.yml`, `LOCAL_DECODE_ONLY`,
> `localstate`, `edge-dashboard`) are on `origin/staging` and were proven
> end-to-end on the bispharma box. The remaining wiring — the CS-Admin toggle
> surfacing and having the Box-Ops **Deploy** step *auto-assemble* the on-prem
> bundle + `.env.onprem` when `onprem_offline=true` — is the small addition ADR-0053
> §9 flags as "still open." Until it lands, the stack is brought up on the box with
> the documented `docker compose -f compose.onprem-edge.yml --env-file .env.onprem
> up -d --build`.

## Image distribution — build on the box

The decoder image builds **on the box from source** — `image:
packiot-sparkplug-decoder:local`, `build.context: ./services/sparkplug-decoder`.
No registry pull and **no PAT** is needed: the box has `buildx`, and
`sparkplug-decoder:local` was proven to build + run on `mi-0114` (the bispharma
amd64 box). This sidesteps the private-registry auth problem that dogs on-box
deploys elsewhere.

## Teardown — leave nothing behind

Removing a client **also brings the on-prem stack down** — `docker compose ...
down -v` (dropping the `edge_localstate` + mosquitto volumes) plus the on-box
bundle cleanup. A decommissioned tenant leaves no orphaned containers, volumes, or
config on the box.

## How it pairs with the operator's offline warning

The operator SPA already shows an **"Offline — showing last-synced data"** banner
(the `OfflineBanner` + `WifiOff` icon), driven by a cloud-reachability probe — it
*warns* the operator that the numbers on the operator screen are stale. This
dashboard is the **live-data counterpart** to that *warning*: same outage, but the
floor gets a screen that is still **live** off the on-box cache instead of only a
"this is stale" notice. See [Frontends, Infra & Auth](07-frontends-infra-auth.md)
for the operator PWA, and [Outage Resilience](10-outage-resilience-and-offline.md)
for the actions/counts buffers.

## Relation to ADR-0053

ADR-0053 splits outage autonomy into two halves:

- **Visibility half — SHIPPED (this page).** On-box decode → local current-state →
  local dashboard, `LOCAL_DECODE_ONLY`, no cloud publish. It keeps the floor
  *seeing* live production; it does **not** add a cloud write path.
- **Durability half — PROPOSED / future.** An on-box **outbox** draining a
  *decoded* SparkPlug stream to the cloud over HTTPS (a new cloud ingress that
  accepts the agent/transformer output — the existing `ingest-shim` speaks a
  different, JSON, format). This is **not** built. For an HTTPS-only factory the
  **raw-tag reader spool already is the durability path** (it buffers + replays raw
  batches over HTTPS), so the decoded-stream outbox is only worth building for a
  client whose outage profile needs decoded-level durability beyond it.

Full rationale, the egress-firewall proof, and the outbox/shim feasibility are in
`docs/adr/0053-on-prem-ingest-edge-for-outage-autonomy.md` (§9 is the B-minimal
implementation).

## Quick reference

| Question | Answer |
|---|---|
| Does this add a second cloud write path? | **No.** `LOCAL_DECODE_ONLY` — zero cloud sockets. Cloud is fed by the reader's primary tee + spool. |
| Can the floor see **live** numbers offline? | **Yes** — the on-box dashboard reads the local current-state cache (this is the piece [page 10](10-outage-resilience-and-offline.md) said was missing). |
| Is it on by default? | **No** — opt-in per client via the "Enable on-prem offline operation" toggle. |
| Why not just uplink from the box? | The factory firewall blocks AMQP/8883; the box egresses HTTPS only. |
| What if the on-prem stack crashes? | The client is exactly where they are today — the reader's cloud path is untouched. |
| outbox vs localstate? | outbox = store-and-forward (durability); localstate = store-and-overwrite (visibility). |
| Where does the decoder image come from? | Built on the box from source (`buildx`), no registry/PAT. |
| Removing a client — is the box cleaned up? | Yes — `compose down -v` + bundle cleanup, nothing left behind. |

See also: [Outage Resilience & Offline Operation](10-outage-resilience-and-offline.md) ·
[Onboarding a Client](02-onboarding.md#2-connect-the-plcs) ·
[Cloud Services & OEE](05-cloud-services-and-oee.md) ·
[Edge & Data Ingestion](04-edge-and-ingestion.md).
