# operator-adapter

The **operator twin of `ingest-shim`**. It bridges Incoplast's bespoke operator
UI (mui_* + Hasura) into staging `user_logs` so the shadow-mirror can replay
operator actions to the `packiot_shadow` (F3) flow and the two flows become
comparable for enterprise 4.

## Why it exists

Incoplast's operators justify downtimes and start POs through a custom Node-RED
+ Hasura app that talks **directly to the DB / SparkPlug** — it never calls our
`edge-api`. Those actions therefore never write staging `user_logs`, so
`shadow-mirror` has nothing to replay to F3.

```
Incoplast Node-RED (operator action)
  │  tee node → HTTPS POST
  ▼
operator-adapter  ── maps Incoplast shape → edge-api DTO ──►  edge-api (F1)
                                                                │ writes user_logs
                                                                ▼
                                                        shadow-mirror ─► packiot_shadow (F3)
```

The adapter is intentionally thin: **authenticate → scope-check → map field
names → inject the enterprise-4 api key → call edge-api → translate status.**
It does **no DB access** and **no topic→id resolution** (see "Unmapped fields").

## Endpoints

| Method | Path | Maps to edge-api |
|--------|------|------------------|
| POST | `/operator/downtime` | `create-manual-event` (id_param 30810/30811) or `edit-manual-event` (30812/30813/30814) |
| POST | `/operator/po` | `create-and-start` |
| GET | `/healthz` | liveness (`{"healthy":true}`) |
| GET | `/metrics` | Prometheus (`operator_adapter_requests_total{action,outcome}`) |

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
| mapped + edge-api 2xx | **202 Accepted** |
| edge-api 4xx | **passthrough** (edge status + body) |
| edge-api 5xx | **502 Bad Gateway** |
| edge-api unreachable | **503 Service Unavailable** |
| required field unmappable | **422 Unprocessable Entity** (names the field) |

**422, not a guess.** A wrong downtime/PO write is worse than a rejected one, so
any required edge-api field the adapter can't fill stops here.

## Configuration (env)

| Var | Required | Default | Notes |
|-----|----------|---------|-------|
| `OPERATOR_API_KEY` | yes | — | shared secret the tee node presents as `X-Ingest-Key` |
| `EDGE_API_KEY` | yes | — | the **enterprise-4 `api_key`** edge-api authenticates. **FILL AT DEPLOY.** Never logged |
| `INCOPLAST_ENTERPRISE_ID` | yes | — | tenant scope (no hardcoded ids in code) |
| `INCOPLAST_TOPIC_PREFIX` | no | — | e.g. `GRANADO`; second scope gate / fallback |
| `EDGE_API_URL` | no | `http://edge-api:8080` | internal edge-api base URL |
| `PORT` | no | `8443` | TLS listen port |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | yes | — | refuses to serve plaintext |

## Field mappings

### `/operator/downtime` — Incoplast `justify event PackML` → edge-api

| Incoplast field | edge-api field | Notes |
|-----------------|----------------|-------|
| `id_equipment` | `idEquipment` | **required** — resolved from topic by the tee node |
| `cd_machine` | `cdMachine` | **required** (edge `@IsNotEmpty`) |
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
| `id_order` (`msg.payload.new_po`, the order number) | `idOrder` | **required** |
| `id_equipment` | `idEquipment` | **required** — resolved from topic by tee node |
| `id_site` | `idSite` | **required** — resolved from topic hierarchy |
| `id_area` | `idArea` | **required** — resolved from topic hierarchy |
| `production_order_quantity` (`po.production_programmed`) | `productionOrderQuantity` | **required** |
| `timestamp` (`msg.ts`) | `timestamp` | **required**, `YYYY-MM-DD HH:mm:ss` |
| `nm_production_order` (`po.nm_product`) | `nmProductionOrder` | optional |
| `notes` | `txtProductionOrderNotes` | optional |
| `id_label` | `idLabel` | optional — omitted if absent |
| `enterprise` + `→idEnterprise=` | `idEnterprise` | injected from config |

## Unmapped fields (deliberate gaps → the tee node must fill them)

The Incoplast operator payload works in **packml_topic strings**, but edge-api
DTOs demand **numeric ids** (`idEquipment`, `idSite`, `idArea`) and quantities
that live in Incoplast's flow context (the matched `_POs` object + entity tree),
**not in the raw operator click**. The adapter does **not** do topic→id
resolution (it has no DB) — that is the tee node's job, using the same
`_POs`/entity context Incoplast's flow already holds.

If any of these are absent the adapter returns **422** naming the field:

- downtime: `id_equipment`, `cd_machine`, `category`, `category_desc`,
  `ts_event`, `ts_end` (+ `id_equipment_event` on the edit path)
- PO: `id_order`, `id_site`, `id_area`, `id_equipment`,
  `production_order_quantity`, `timestamp`

## Node-RED tee-node spec

Add a **function node + http request node** to Incoplast's flow, wired to the
output of `justify event PackML` and `start new po` (tee = a second wire off the
existing node, so the original SparkPlug path is untouched).

Function node (`tee → operator-adapter`), downtime example:

```javascript
// Runs off the `justify event PackML` output wire.
var cat = (msg.payload['set_event_categoria']    || '').split('.|:');
var sub = (msg.payload['set_event_subcategoria'] || '').split('.|:');
msg.headers = { 'X-Ingest-Key': env.get('OPERATOR_API_KEY'), 'Content-Type': 'application/json' };
msg.url = 'https://operator-adapter:8443/operator/downtime';
msg.method = 'POST';
msg.payload = {
    enterprise:         4,
    topic:              flow.get('app_user_topic_' + msg.socketid),
    id_param:           msg.metrics[0].id,               // 30810..30814
    id_equipment:       flow.get('id_equipment_' + msg.socketid), // resolve from topic
    id_equipment_event: msg.payload['set_event_id'],     // edit path
    cd_machine:         flow.get('cd_machine_' + msg.socketid),   // equipment code
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
msg.headers = { 'X-Ingest-Key': env.get('OPERATOR_API_KEY'), 'Content-Type': 'application/json' };
msg.url = 'https://operator-adapter:8443/operator/po';
msg.method = 'POST';
var po = (global.get('_POs') || []).find(p => p.id_order == msg.payload['new_po']) || {};
msg.payload = {
    enterprise:                4,
    topic:                     flow.get('app_user_topic_' + msg.socketid),
    id_order:                  msg.payload['new_po'],
    id_site:                   flow.get('id_site_' + msg.socketid),
    id_area:                   flow.get('id_area_' + msg.socketid),
    id_equipment:              flow.get('id_equipment_' + msg.socketid),
    production_order_quantity: po.production_programmed,
    nm_production_order:       po.nm_product,
    timestamp:                 new Date(msg.ts).toISOString().slice(0,19).replace('T',' ')
};
return msg;
```

Then an **http request** node (method: set from msg, return: parsed JSON). A 202
means the action landed in `user_logs`; a 422 means a field above resolved to
`undefined` — fix the resolution in the tee node, do not weaken the adapter.

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
3. `docker compose -f compose.staging.yml up -d --build operator-adapter`.
4. Verify `GET https://<host>:8445/healthz` → `{"healthy":true}`.
5. Add the tee nodes in Incoplast Node-RED (spec above); set `OPERATOR_API_KEY`
   in that Node-RED's env.
6. Fire one test downtime + PO; confirm a new `user_logs` row in F1 and its twin
   in `packiot_shadow` (F3).
