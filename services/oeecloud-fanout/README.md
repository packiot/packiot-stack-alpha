# oeecloud-fanout — re-tenant twin fan-out

Roadmap **P1 / task #17**. Makes the STAGING sandbox tenant **SBXCPACK**
(enterprise 2000003) a faithful ALL-LINES twin of the real **CPACK** tenant
(enterprise 3) by fanning out staging's live CPACK decoded SparkPlug stream,
re-tenanting it, and republishing it so the sandbox's `oeecloud-worker` queue
writes SBXCPACK F3 rows.

```
edge-transformer ──sparkplug.data──▶  oee (topic exchange)
                                        │  (a COPY to every bound queue)
              ┌─────────────────────────┼──────────────────────────────┐
              ▼                          ▼                              ▼
  oeecloud-worker-q            oeecloud-fanout-cpack-to-sbxcpack   (other tenants…)
  (CPACK → ent 3, unchanged)   (THIS service)
                                        │  retenant CPACK/… → SBXCPACK/…
                                        │  clear inherited equipment ids
                                        ▼  publish sparkplug.data.sbxcpack
                                     oee (topic exchange)
                                        ▼
                             oeecloud-worker-q-sbxcpack  → SBXCPACK F3 (ent 2000003)
```

## Envelope shape (what it rewrites)

The sparkplug-decoder publishes the oeecloud-compatible envelope
(`analyticspub.Envelope`):

```json
{ "timestamp": 1782161858551, "gateway": "edge-transformer:outbox",
  "source_type": "refactored",
  "metrics": [ { "name": "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
                 "timestamp": 1782161858551, "value": 12, "counter": 830123 } ] }
```

**The tenant is not a field** — the worker derives it from the first metric
name's first segment (the SparkPlug GroupID), lowercased. So rewriting that
segment `CPACK → SBXCPACK` on every metric name re-tenants the whole envelope.
The transform preserves timestamps/values/counters/source_type byte-for-byte
(decoded with `json.Number` so large integers round-trip exactly).

The per-metric `id` is the PackML **parameter** id (30700-30899) the worker needs
for PO-control classification — it is deliberately **not** cleared. Only true
equipment-id fields (`id_equipment`/`equipment_id`, absent on today's wire) are
cleared, forward-safely, so the sandbox worker re-resolves against its own
SBXCPACK `packml_register` rows.

## Routing-key assumption

The staging edge-transformer publishes the **2-segment `sparkplug.data`** key
(tenant inside the envelope — verified in `services/edge-transformer/cmd/
edge-transformer/main.go`; there is **no `F3_PER_TENANT_ROUTING` flag** anywhere
in the tree). The fan-out queue binds BOTH `sparkplug.data` and
`sparkplug.data.cpack` so it keeps working if per-tenant routing is ever added.
Because `sparkplug.data` carries **every** tenant, the transform gates on
`group == CPACK` and acks non-CPACK messages without republishing.

## Why it can't double-count or loop

- **No double-count:** the clone is published ONLY to `sparkplug.data.sbxcpack`.
  CPACK's own worker queue is a separate queue that receives its own COPY from
  the exchange and keeps writing ent-3 rows exactly once. Source (ent 3) and
  target (ent 2000003) have disjoint equipment ids and F3 rows. This is why a
  CROSS-tenant fan-out is safe where the retired SAME-tenant `mirror-worker-go`
  had to be the sole writer.
- **No self-feedback:** the target key `sparkplug.data.sbxcpack` matches neither
  of this consumer's exact bindings (`sparkplug.data`, `sparkplug.data.cpack`),
  so a clone is never redelivered here. The transform's group check is a second
  guard (a target-group message is reported not-ours).

## Delivery semantics

At-least-once, idempotent: republish uses broker publish-confirms; the source is
acked only after a confirmed republish. A broker nack/timeout requeues the
source for retry. A crash between confirm and ack redelivers → a duplicate
clone, which is safe because the target worker's writes are UPSERTs.

## Enable on staging

Off by default. In staging `.env`:

```
FANOUT_CPACK_TO_SBXCPACK_ENABLED=true
```

then restart the `oeecloud-fanout` service. While disabled it serves `/health`
(healthy) and idles — binds no queue, consumes nothing.

## Config (env)

| Var | Default | Meaning |
|-----|---------|---------|
| `FANOUT_ENABLED` | `false` | Master gate (generic name — set this for any NEW twin) |
| `FANOUT_CPACK_TO_SBXCPACK_ENABLED` | `false` | Legacy alias for `FANOUT_ENABLED`, kept as a fallback so this instance's already-deployed `.env` flag keeps working unchanged |
| `FANOUT_SOURCE_GROUP` | `CPACK` | Source SparkPlug GroupID |
| `FANOUT_TARGET_GROUP` | `SBXCPACK` | Target GroupID |
| `FANOUT_QUEUE` | `oeecloud-fanout-cpack-to-sbxcpack` | Durable queue |
| `FANOUT_SOURCE_ROUTING_KEYS` | `sparkplug.data,sparkplug.data.cpack` | Bindings (CSV) |
| `FANOUT_TARGET_ROUTING_KEY` | `sparkplug.data.sbxcpack` | Republish key |
| `SOURCE_EXCHANGE` | `oee` | Topic exchange |
| `PREFETCH` | `50` | Consumer prefetch |
| `PUBLISH_CONFIRM_TIMEOUT_MS` | `5000` | Publish-confirm deadline |
| `HEALTH_PORT` | `9102` | /health port |
| `RABBITMQ_SECRET_ID` | `packiot/staging/rabbitmq-oeecloud-creds` | AMQP creds (reuses the worker's least-priv user) |

## Templatable per twin (#22) — DONE

Source/target groups, queue, routing keys, and now the master-gate name are all
env-driven, so a single image serves any (source tenant → target tenant) pair —
nothing in this service is CPACK/SBXCPACK-specific.

The generator that emits a new twin's compose-service block + `.env` flag now
exists: `scripts/emit-fanout-config.sh SOURCE_GROUP TARGET_GROUP [HEALTH_PORT]
[IP_LAST_OCTET]`. `scripts/provision-sandbox-tenant.sh` (the twin's DB-side
clone) calls it automatically on `--create`/`--reset`, writing
`configs/fanout/<target_group_lower>.yml`. Both are idempotent (pure template,
deterministic overwrite) — re-provisioning a twin re-emits the same fan-out
config, and provisioning a brand-new twin (different `SOURCE_GROUP`/
`TARGET_GROUP` env vars) emits its own file with no code change.

What's still manual: splicing the emitted `services:` block into
`compose.staging.yml` (or loading it via a second `-f`), picking an unused
`packiot-net` IP/health-port for a brand-new pair, and flipping the emitted
`.env` flag — see the generated file's header comment. There is no CSAdmin UI
trigger for this yet; today it is a CS/eng step run alongside twin
provisioning, not a button in CSAdmin's onboarding wizard.
