# operator-adapter

The **operator twin of `ingest-shim`**. It bridges Incoplast's bespoke operator
UI (mui_* + Hasura) into staging `user_logs` so the shadow-mirror can replay
operator actions to the `packiot_analytics` (F3) flow and the two flows become
comparable for enterprise 4.

## Why it exists

Incoplast's operators justify downtimes and start POs through a custom Node-RED
+ Hasura app that talks **directly to the DB / SparkPlug** — it never calls our
`edge-api`. Those actions therefore never write staging `user_logs`, so
`shadow-mirror` has nothing to replay to F3.

```
Incoplast Node-RED (operator action)
  │  tee node → HTTPS POST  (packml_topic + action fields)
  ▼
operator-adapter  ── resolve packml_topic → staging ids (packml_register) ──┐
                  ── map Incoplast shape → edge-api DTO ──►  edge-api (F1)   │
                                                                │ writes user_logs
                                                                ▼            │
                                                        shadow-mirror ─► packiot_analytics (F3)
                  read-only Postgres pool (F1 `packiot`) ◄──────────────────┘
```

The adapter's job: **authenticate → scope-check → resolve packml_topic → map
field names → inject the enterprise-4 api key → call edge-api → translate
status.**

**Topic → id resolution (new).** Incoplast's Node-RED only holds packml
**topics** and its **own** production ids — NOT the staging (enterprise-4) ids we
seeded (sequence-assigned, so they differ). The link between the two worlds is
the topic. So the adapter resolves it, exactly like `oeecloud-worker` does for
the data path: a small **read-only** Postgres pool queries `packml_register`
(joined to `equipments → areas → sites`) to turn the topic into the staging
`id_equipment` / `cd_machine` / `id_area` / `id_site`. The tee node therefore
sends the **topic it has**, not ids it can't know.

Resolution fails **closed**: a topic that is unknown, inactive, **cross-tenant**
(the join is gated on `sites.id_enterprise = INCOPLAST_ENTERPRISE_ID`), or
ambiguous (>1 active `packml_register` row) never resolves — the handler returns
**422** rather than guessing an id.

## Endpoints

| Method | Path | Maps to edge-api | user_logs eventType |
|--------|------|------------------|---------------------|
| POST | `/operator/downtime` | `create-manual-event` (id_param 30810/30811) or `edit-manual-event` (30812/30813/30814) | `manual-event-created` / `manual-event-edited` |
| POST | `/operator/po` | `create-and-start` | `order-created-started` |
| POST | `/operator/po/stop` | `stop` | `order-stopped` |
| POST | `/operator/po/setup` | `setup` (close current + optionally open next) | `order-changed` |
| POST | `/operator/po/replace` | `replace` | `order-replaced` |
| POST | `/operator/po/change-status` | `change-status` | `order-status-changed` |
| POST | `/operator/po/change-time` | `change-time` | `order-time-changed` |
| POST | `/operator/split` | `downtimes/split` (one event → re-categorised sub-intervals) | `event-splitted` |
| GET | `/healthz` | liveness + **DB pool reachability** (`{"healthy":true,"db":true}`; 503 if the resolver's pool is down) | — |
| GET | `/metrics` | Prometheus (`operator_adapter_requests_total{action,outcome}`) | — |

The five `/operator/po/*` routes are **action-driven**, one per edge-api
production-orders endpoint — *not* a decoder of Incoplast's raw SparkPlug
`Parameter[30800..30803]` convention. The adapter is an anti-corruption layer
whose stable contract is edge-api's own semantics; each client's tee node does
the small translation from its private flow representation to these routes. That
keeps the adapter client-agnostic (one route == one endpoint == one eventType)
instead of coupling it to one factory's parameter encoding. Every `/operator/po/*`
route resolves `packml_topic` → staging ids and shares the same
auth/scope/422/503 semantics as `/operator/downtime`.

### Scrap is NOT a route here (it's data-path)

In the operator flow, scrap corrections are emitted as **counter metrics**
(`Admin/ProdDefectiveCount` / `ProdConsumedCount` / `ProdProcessedCount`, plus a
`Parameter[30850]` marker) — raw time-series, not an edge-api call. **edge-api
has no scrap endpoint**; final good-count corrections ride *inside* the stop /
setup bodies (`productionOrderQuantity` / `oldProductionOrderProdFinal`). So
scrap is bridged by the **data tee** (→ `ingest-shim` → worker → `equipment_values`),
exactly like PLC counters — never by this adapter. If you need to mirror scrap,
tee those counter metrics through the data path, not `/operator/*`.

### Auth & scope

- **Inbound**: the tee node must present `X-Ingest-Key: $OPERATOR_API_KEY`
  (constant-time compared). Missing/wrong → **401**.
- **Scope**: the action must belong to Incoplast. Rejected (**403**) unless the
  body's `enterprise` equals `INCOPLAST_ENTERPRISE_ID` **or** the `topic` sits
  under `INCOPLAST_TOPIC_PREFIX`. Fails closed if neither can be confirmed.
- **Outbound**: the adapter calls `edge-api` internally with `x-api-key:
  $EDGE_API_KEY` (the enterprise-4 `api_key`) plus `?idEnterprise=<id>` so
  edge-api's audit logger attributes `user_logs` to the right tenant.

### Status translation

| Condition | Adapter response |
|-----------|------------------|
| resolved + mapped + edge-api 2xx | **202 Accepted** |
| edge-api 4xx | **passthrough** (edge status + body) |
| edge-api 5xx | **502 Bad Gateway** |
| edge-api unreachable | **503 Service Unavailable** |
| `packml_topic` missing / unknown / inactive / cross-tenant / ambiguous | **422 Unprocessable Entity** (`topic … did not resolve to a staging equipment`) |
| required **action** field unmappable | **422 Unprocessable Entity** (names the field) |
| resolver DB/transport error | **503 Service Unavailable** (retryable — NOT a rejection) |

**422, not a guess.** A wrong downtime/PO write is worse than a rejected one, so
any topic the adapter can't confidently resolve, or any required edge-api field
it can't fill, stops here. A resolver **DB** error is a **503** instead (the
topic might resolve on retry), so we never poison the negative cache with a
transient failure.

## Configuration (env)

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `OPERATOR_API_KEY` | yes | — | shared secret the tee node presents as `X-Ingest-Key` |
| `EDGE_API_KEY` | yes | — | the **enterprise-4 `api_key`** edge-api authenticates. **FILL AT DEPLOY.** Never logged |
| `INCOPLAST_ENTERPRISE_ID` | yes | — | tenant scope (no hardcoded ids in code) |
| `INCOPLAST_TOPIC_PREFIX` | no | — | e.g. `GRANADO`; second scope gate / fallback |
| `EDGE_API_URL` | no | `http://edge-api:8080` | internal edge-api base URL |
| `PG_SECRET_ID` | no | `packiot/staging/db` | AWS Secrets Manager id for the read-only resolver DB creds (F1 `packiot`). Secret shape `{host,port,user,password,name}` |
| `AWS_REGION` | no | `us-east-1` | region for the Secrets Manager lookup |
| `CREDS_SOURCE` | no | — | set to `env` (dev only) to read DB creds from `DB_HOST`/`DB_PORT`/`DB_USER`/`DB_PASSWORD`/`DB_NAME` instead of Secrets Manager |
| `PORT` | no | `8443` | TLS listen port |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | yes | — | refuses to serve plaintext |

The resolver's Postgres pool is **small (max 3 conns)** and **read-only** — it
only `SELECT`s from `packml_register`/`equipments`/`areas`/`sites`. It connects
to **F1 `packiot`** (where edge-api writes) so the ids it resolves are exactly
the ones edge-api accepts. Use a least-privilege DB role.

## Field mappings

### `/operator/downtime` — Incoplast `justify event PackML` → edge-api

| Incoplast field | edge-api field | Notes |
|-----------------|----------------|-------|
| `packml_topic` | — | **required** — the adapter resolves it → `idEquipment` + `cdMachine` |
| _(resolved)_ `id_equipment` | `idEquipment` | filled by the adapter from `packml_topic` (`packml_register.id_equipment`) |
| _(resolved)_ `cd_machine` | `cdMachine` | filled by the adapter from `packml_topic` (`equipments.cd_equipment`) |
| `category` (`set_event_categoria[0]`) | `cdCategory` | **required** |
| `category_desc` (`set_event_categoria[3]`) | `descCategory` | **required** |
| `subcategory` (`set_event_subcategoria[0]`) | `cdSubcategory` | |
| `subcategory_desc` (`set_event_subcategoria[1]`) | `descSubcategory` | |
| `txt_downtime` (`set_event_text`) | `txtDowntimeNotes` | |
| `ts_event` | `tsEvent` (create) / `start` (edit) | **required**, ISO 8601 |
| `ts_end` | `tsEnd` (create) / `end` (edit) | **required**, ISO 8601 |
| `id_equipment_event` (`set_event_id`) | `idEquipmentEvent` | **required on edit path** |
| `planned_dwt` (`set_event_categoria[1]`) | `plannedDowntime` | edit path only |
| `change_over` (`set_event_categoria[2]`) | `changeOver` | edit path only |
| `idle` (`set_event_categoria[4]`) | `idle` | edit path only |
| `enterprise` + `→idEnterprise=` | `idEnterprise` | injected from config, not the body |
| `user`, `sector`, `timezone` | — | audit-only; not part of edge DTO |

Routing: `id_param` 30810/30811 → **create-manual-event**; 30812/30813/30814 →
**edit-manual-event**.

### `/operator/po` — Incoplast `start new po` → edge-api `create-and-start`

| Incoplast field | edge-api field | Notes |
|-----------------|----------------|-------|
| `packml_topic` | — | **required** — the adapter resolves it → `idEquipment` + `idArea` + `idSite` |
| `id_order` (`msg.payload.new_po`, the order number) | `idOrder` | **required** |
| _(resolved)_ `id_equipment` | `idEquipment` | filled by the adapter from `packml_topic` |
| _(resolved)_ `id_site` | `idSite` | filled by the adapter from the topic hierarchy (`areas → sites`) |
| _(resolved)_ `id_area` | `idArea` | filled by the adapter from the topic hierarchy (`equipments.id_area`) |
| `production_order_quantity` (`po.production_programmed`) | `productionOrderQuantity` | **required** |
| `timestamp` (`msg.ts`) | `timestamp` | **required**, `YYYY-MM-DD HH:mm:ss` |
| `nm_production_order` (`po.nm_product`) | `nmProductionOrder` | optional |
| `notes` | `txtProductionOrderNotes` | optional |
| `id_label` | `idLabel` | optional — omitted if absent |
| `enterprise` + `→idEnterprise=` | `idEnterprise` | injected from config |

### `/operator/po/*` — PO lifecycle → edge-api production-orders

Every route below resolves `packml_topic` → `idEquipment` (and `idArea`/`idSite`
for `setup`). The tee sends the topic + the fields it owns from flow context (the
matched `_POs` object / `msg.payload`). Required fields (fail-closed 422 if absent):

| Route | edge-api DTO | Required inbound fields (beyond `packml_topic`) | Optional |
|-------|--------------|--------------------------------------------------|----------|
| `stop` | `StopProductionOrderDto` | `timestamp`, `stop_type` (`pause`\|`finish` or `1`\|`2`), `id_production_order`, `production_order_quantity` | — |
| `setup` | `SetupProductionOrderDto` | `timestamp`, `should_open_new_po`, `stop_type`, `old_id_production_order`, `old_production_order_prod_final` (+ `id_order` when `should_open_new_po`+`should_create_po`; `id_production_order` when opening an existing next PO) | `production_order_quantity`, `id_label`, `nm_production_order`, `notes` |
| `replace` | `ReplaceProductionOrderDto` | `id_production_order` (the PO to switch to) | — |
| `change-status` | `ChangeStatusProductionOrderDto` | `id_production_order` | — |
| `change-time` | `ChangeTimeProductionOrderDto` | `id_production_order_runtime`, `id_production_order`, `start` | `end` |

`stop_type` accepts edge-api's canonical `pause`/`finish` **or** Incoplast's
numeric convention (`1` = interrupt→`pause`, `2` = `finish`), so the tee can
forward `msg.payload['stop_type']` as-is. `id_enterprise` and the resolved
`idEquipment`/`idArea`/`idSite` are never trusted from the caller — the adapter
injects config + resolver values.

Incoplast node → route: `change po - open e close` maps to **setup** when it
opens the next PO (`new_po != no_new_po`) and to **stop** when it only closes;
`change PO PackML` (set_po_number) maps to **replace**; the `po_manual_change_*`
and time-correction actions map to **change-status** / **change-time**.

Tee example (off `change po - open e close`, close-and-open-next → **setup**):

```javascript
// Runs off the `change po - open e close` output wire.
// stop_type comes straight from the node (1=interrupt, 2=finish).
msg.headers = { 'X-Ingest-Key': env.get('OPERATOR_API_KEY'), 'Content-Type': 'application/json' };
msg.method = 'POST';
var opensNext = msg.payload['new_po'] !== 'no_new_po';
var nextPo = (global.get('_POs') || []).find(p => p.id_order == msg.payload['new_po']) || {};
if (opensNext) {
    msg.url = 'https://operator-adapter:8443/operator/po/setup';
    msg.payload = {
        enterprise:                     4,
        packml_topic:                   flow.get('packml_topic_' + msg.socketid),
        timestamp:                      new Date(msg.payload['ts_po_end']).toISOString().slice(0,19).replace('T',' '),
        should_open_new_po:             true,
        should_create_po:               false,               // reuse the already-created next PO row
        stop_type:                      msg.payload['stop_type'], // 1|2 → pause|finish
        old_id_production_order:        msg.payload['current_po'],
        old_production_order_prod_final: msg.payload['po_manual_change_real_quantity'],
        id_production_order:            nextPo.id_production_order,
        production_order_quantity:      nextPo.production_programmed,
        nm_production_order:            nextPo.nm_product
    };
} else {
    msg.url = 'https://operator-adapter:8443/operator/po/stop';
    msg.payload = {
        enterprise:                4,
        packml_topic:              flow.get('packml_topic_' + msg.socketid),
        timestamp:                 new Date(msg.payload['ts_po_end']).toISOString().slice(0,19).replace('T',' '),
        stop_type:                 msg.payload['stop_type'],
        id_production_order:       msg.payload['current_po'],
        production_order_quantity: msg.payload['po_manual_change_real_quantity']
    };
}
return msg;
```

`replace` / `change-status` / `change-time` follow the same shape — set `msg.url`
to the route and `msg.payload` to the required fields from the table above.

## What the tee sends vs. what the adapter resolves

The Incoplast operator payload works in **packml_topic strings**, but edge-api
DTOs demand **numeric staging ids** (`idEquipment`, `idSite`, `idArea`) +
`cdMachine`. Incoplast's Node-RED does **not** know those ids — we seeded them
into staging sequence-assigned, so they differ from Incoplast's own production
ids. The **only** thing that links the two worlds is the **topic**.

So the split of responsibility is:

- **The tee node sends the topic + the action fields it genuinely owns.** It no
  longer sends `id_equipment` / `id_site` / `id_area` / `cd_machine` — it can't
  know them.
- **The adapter resolves the ids** from `packml_topic` against `packml_register`
  (read-only pool, F1 `packiot`), gated on `INCOPLAST_ENTERPRISE_ID`.

The adapter returns **422** when:

- `packml_topic` is missing, or does not resolve (unknown / inactive /
  cross-tenant / ambiguous) → `topic … did not resolve to a staging equipment`
- a still-missing **action** field the tee owns is absent:
  - downtime: `category`, `category_desc`, `ts_event`, `ts_end`
    (+ `id_equipment_event` on the edit path)
  - PO: `id_order`, `production_order_quantity`, `timestamp`

## Node-RED tee-node spec

Add a **function node + http request node** to Incoplast's flow, wired to the
output of `justify event PackML` and `start new po` (tee = a second wire off the
existing node, so the original SparkPlug path is untouched).

Function node (`tee → operator-adapter`), downtime example:

```javascript
// Runs off the `justify event PackML` output wire.
// The tee sends the packml_topic + the action fields — NO id_equipment /
// cd_machine (the adapter resolves those from the topic).
var cat = (msg.payload['set_event_categoria']    || '').split('.|:');
var sub = (msg.payload['set_event_subcategoria'] || '').split('.|:');
msg.headers = { 'X-Ingest-Key': env.get('OPERATOR_API_KEY'), 'Content-Type': 'application/json' };
msg.url = 'https://operator-adapter:8443/operator/downtime';
msg.method = 'POST';
msg.payload = {
    enterprise:         4,
    packml_topic:       flow.get('packml_topic_' + msg.socketid), // the adapter resolves → staging ids
    id_param:           msg.metrics[0].id,               // 30810..30814
    id_equipment_event: msg.payload['set_event_id'],     // edit path only
    category:           cat[0], category_desc: cat[3],
    subcategory:        sub[0], subcategory_desc: sub[1],
    planned_dwt:        cat[1] === 'true', change_over: cat[2] === 'true', idle: cat[4],
    txt_downtime:       msg.payload['set_event_text'] || '',
    ts_event:           msg.metrics[0].ts_event,
    ts_end:             msg.metrics[0].ts_end
};
return msg;
```

PO example (off `start new po`):

```javascript
// The tee sends the packml_topic + the order fields — NO id_site / id_area /
// id_equipment (the adapter resolves the hierarchy from the topic).
msg.headers = { 'X-Ingest-Key': env.get('OPERATOR_API_KEY'), 'Content-Type': 'application/json' };
msg.url = 'https://operator-adapter:8443/operator/po';
msg.method = 'POST';
var po = (global.get('_POs') || []).find(p => p.id_order == msg.payload['new_po']) || {};
msg.payload = {
    enterprise:                4,
    packml_topic:              flow.get('packml_topic_' + msg.socketid), // the adapter resolves → staging ids
    id_order:                  msg.payload['new_po'],
    production_order_quantity: po.production_programmed,
    nm_production_order:       po.nm_product,
    timestamp:                 new Date(msg.ts).toISOString().slice(0,19).replace('T',' ')
};
return msg;
```

Then an **http request** node (method: set from msg, return: parsed JSON). A 202
means the action landed in `user_logs`. A 422 means either the `packml_topic`
did not resolve to a staging equipment (the topic isn't in `packml_register`,
isn't `active`, or belongs to another tenant — fix the CS-Admin registration,
**not** the adapter) or a required **action** field was `undefined` (fix the tee
node). A 503 means the adapter's resolver DB was briefly unreachable — retry.

> Where does `packml_topic_<socketid>` come from? It's the SparkPlug topic the
> operator's session is already bound to in the flow. If Incoplast stores it
> under a different flow key, point the tee at that key — the value must be the
> exact string in `packml_register.packml_topic`.

## Local checks

```bash
cd services/operator-adapter
go build ./... && go vet ./... && go test -race ./...
gofmt -l .   # empty = clean
```

## Deploy checklist

1. Issue/copy a TLS cert+key to `/opt/packiot/operator-adapter/certs/` on the
   staging host (mounted read-only at the same path).
2. Fill secrets in the deploy env: `OPERATOR_API_KEY` (new shared secret) and
   `EDGE_API_KEY` = the **enterprise-4 `api_key`** (`SELECT api_key FROM
   enterprises WHERE id_enterprise = 4`).
2b. Ensure the EC2 IAM role can read `PG_SECRET_ID` (`packiot/staging/db`) and
   that pgbouncer is reachable on `packiot-net` — the resolver opens a read-only
   pool at boot and the container exits if it can't connect. Grant the DB user
   `SELECT` on `packml_register`, `equipments`, `areas`, `sites`.
3. `docker compose -f compose.staging.yml up -d --build operator-adapter`.
4. Verify `GET https://<host>:8445/healthz` → `{"healthy":true,"db":true}`
   (503 if the resolver's DB pool is down).
5. Add the tee nodes in Incoplast Node-RED (spec above); set `OPERATOR_API_KEY`
   in that Node-RED's env.
6. Fire one test downtime + PO; confirm a new `user_logs` row in F1 and its twin
   in `packiot_analytics` (F3).
