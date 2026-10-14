---
title: Glossary
layer: 0
owner_area: platform
last_verified: 2026-10-13
---
# Glossary

> **Layer 0 · Start here.** Terms used across the wiki, with a link to where each is
> explained in depth. Up: [Home](../index.md)

## Customizing a client (plain words)

| Term | Meaning | More |
|---|---|---|
| **Factory box** | The small computer we install at the client. It reads the PLCs and sends the values to Packiot. | [Setting up a new client](../use/setting-up-a-client.md) |
| **Customization Hub / Customize app** | The app the automation team uses to change how one client's data is handled: calculations, OEE settings and Node-RED flows. | [Customize](../use/customize/index.md) |
| **Data collector** | The program on our servers that receives the values from the factory boxes and runs the calculations (the shared agent). | [Calculations](../use/customize/calculations.md) |
| **Save** | Stores your change. It does not change live data until you press **Apply now**. | [Customize](../use/customize/index.md) |
| **Apply now** | Makes the saved change live in a few seconds, without losing data. For calculations it restarts the data collector; for OEE settings it restarts the OEE calculator. Only new results use the change; past results stay as they were. | [Calculations](../use/customize/calculations.md), [OEE settings](../use/customize/oee-settings.md) |
| **Compare-and-swap save** | A save that is refused (HTTP 409 conflict) if someone else saved the same client after you opened the page. You reload and make your change again, so nobody's work is silently overwritten. | [Customize](../understand/components/customize.md) |
| **OEE settings (per line)** | How OEE is worked out for a client, with optional different settings for single lines. | [OEE settings](../use/customize/oee-settings.md) |
| **Lead machine** | The main machine of a line — the one whose counter says what the line produced. | [OEE settings](../use/customize/oee-settings.md) |
| **Calculation** | A new counter made from existing ones with a formula (e.g. scrap = what went in − good parts). | [Calculations](../use/customize/calculations.md) |
| **Connection point** | A place on the factory box's PLC reader where a Node-RED flow can receive a copy of the data, or send extra values. | [Node-RED flows](../use/customize/node-red-flows.md) |
| **Node-RED** | A visual tool where you build logic by connecting boxes ("nodes") with wires. | [Node-RED flows](../use/customize/node-red-flows.md) |
| **Node-RED helper** | Node-RED added next to the Python PLC reader on a factory box. It gets a copy of every batch the reader sends and can send extra values. If it breaks, the reader and the data are not affected. | [Node-RED flows](../use/customize/node-red-flows.md) |
| **Device key** | The permanent ID of one machine, used by the factory box to say which machine a value belongs to. It never changes when a machine is renamed. In CS Admin onboarding, the build step offers **Create missing device keys**. | [Setting up a new client](../use/setting-up-a-client.md) |
| **Out-of-service window** | Days when a line is deliberately not in use (not commissioned yet, waiting for its PLC, retired). Set in CS Admin → Lines → line settings → **Out of service**. Those days are left out of the line's OEE and its production target. | [Troubleshooting OEE](../use/troubleshooting-oee.md) |

## Manufacturing and OEE

| Term | Meaning | More |
|---|---|---|
| **OEE** | Overall Equipment Effectiveness = **A × P × Q**. The share of planned production time spent making good product at ideal speed. | [Domain model](../understand/architecture/domain-model.md#oee) |
| **Availability (A, `oee_a`)** | running time ÷ planned production time (available time). | [Domain model](../understand/architecture/domain-model.md#oee) |
| **Performance (P, `oee_p`)** | actual output ÷ output at ideal speed over the running time. Stored and shown **raw, not capped**: it can exceed 100 % (for example when the ideal speed is set too low). | [Domain model](../understand/architecture/domain-model.md#oee) |
| **Quality (Q, `oee_q`)** | net (good) ÷ gross (total). | [Domain model](../understand/architecture/domain-model.md#oee) |
| **Planned downtime** | Stops that are scheduled (lunch, planned maintenance, no order). Removed from the Availability denominator. | [Domain model](../understand/architecture/domain-model.md#time-model) |
| **Gross / net / scrap** | gross = units consumed (input), net = good units produced (output), scrap = gross − net. | [Domain model](../understand/architecture/domain-model.md#counters) |
| **Consumed / Processed / Defective count** | PackML counter names on the PLC for gross, net and scrap. | [Domain model](../understand/architecture/domain-model.md#counters) |
| **Ideal speed** | Rated units per minute (`production_speed`, PackML parameter 30701). | [Domain model](../understand/architecture/domain-model.md#oee) |
| **Production order (PO / OP)** | A job to make N units of a product on a line. Lifecycle: available → running → paused → finished. | [Domain model](../understand/architecture/domain-model.md#production-orders) |
| **PO number (client number)** | The client's own number for a PO. Text, kept exactly as given (`08396260` is not `8396260`), unique per enterprise. Column `id_order_text`; APIs return it as `order_number`. The old integer `id_order` is being retired. | [ADR-0062](../adr/0062-production-order-identity-and-alphanumeric-numbers.md) |
| **`id_production_order` / `po_uuid`** | `id_production_order` is the internal PO key every other table joins on. `po_uuid` (a UUIDv7) is the handle used when an id is created outside the database, and the number the stack uses when it must invent one. | [ADR-0062](../adr/0062-production-order-identity-and-alphanumeric-numbers.md) |
| **Shift** | A named working period (e.g. 06:30–15:00). Shift hours are stored as seconds from `week_begin`. | [Domain model](../understand/architecture/domain-model.md#time-model) |
| **Downtime / event** | A state interval (running, stopped, planned stop…) for a machine or line; operators justify stops with a reason code. | [Domain model](../understand/architecture/domain-model.md#events-and-downtime) |
| **Box / label scan** | A packed box whose barcode (`op;number;quantity`) is scanned by the barcode app; samples are counted separately. | [Barcode app](../understand/components/barcode-app.md) |

## Equipment and tenancy

| Term | Meaning |
|---|---|
| **Enterprise** | A client company (the tenant). CPACK = analytics enterprise **3** (legacy **1**); Bispharma = **5**; Incoplast = **4**; the CPACK sandbox twin = **2000003**. |
| **Site / area** | Plant / section of a plant. Hierarchy: enterprise → site → area → equipment. |
| **Equipment, `tp_equipment`** | 1 = machine, 2 = sector, 3 = line. |
| **Lead machine** | The machine whose signals stand for a line's availability and events (PackML parameter 30702). |
| **Line-lead** | Deriving a line's counters and availability from its member machines (`gross_machine`, `net_machine`, `lead_machine`). See [stream-engine](../understand/components/stream-engine.md). |
| **Counters-only client** | A factory whose PLCs send counts but no machine state; availability is derived from count activity. |
| **Sandbox twin** | Tenant 2000003 (staging): a copy of CPACK used for tests, E2E and rehearsals. Its ids are CPACK's ids + 2,000,000. It heals itself back to the CPACK state after a grace period with no hands-on changes. See [Sandbox for testing](../use/sandbox-for-testing.md) and [Sandbox twin](../understand/components/sandbox-twin.md). |
| **Heal (sandbox reset)** | Resetting the sandbox twin to an exact copy of CPACK-Staging: POs, stops, configuration and barcode scans. Runs when the grace period ends, nightly at 06:00 UTC unless held, or on `heal-now`. |
| **Grace period, hold** | A change in the sandbox *holds* it: no heal runs until the grace period (default 4 h) after the last change, or a manual `extend`. See [The reset rule](../use/sandbox-for-testing.md#the-reset-rule). |
| **Mirror tenant** | On staging, enterprise 3 is a mirror of legacy CPACK, kept in step by the legacy replicator. |
| **Mirror tenant write block** | Staging-only edge-api guard: PO, downtime and shift writes for the mirror tenant (enterprise 3) are refused with 403, and the message points to the sandbox twin. Env `OPERATOR_WRITE_BLOCKED_ENTERPRISES`. See [edge-api](../understand/components/edge-api.md). |
| **Tenant fence** | Server-side rule that every read/write is scoped to the caller's enterprise, resolved from its credential, never from the request. See [Tenancy & security](../understand/architecture/tenancy-and-security.md). |

## Platform

| Term | Meaning |
|---|---|
| **Sparkplug B** | MQTT payload convention used between the factory and the cloud (birth/death certificates, metric aliases). |
| **PackML** | ISA-TR88 naming for machine states and counters; Packiot uses PackML parameter ids (30700–30899). |
| **Topic routing / `packml_register`** | Map from a Sparkplug (PackML-named) topic to an `id_equipment` (`core.topic_routing`; `core.packml_register` is a compatibility view). Being replaced by device bindings ([ADR-0061](../adr/0061-remove-packml-from-the-cloud.md)). |
| **Device binding** | `core.device_bindings`: device key → `id_equipment`, one active key per equipment. The cloud binds data by the key the box declares in its birth message, not by topic names ([ADR-0061](../adr/0061-remove-packml-from-the-cloud.md)). |
| **Medallion** | The analytics DB's layering: **bronze** (raw as received) → **silver** (cleaned facts) → **gold** (OEE grains) → **serving** (API-shaped functions/views). |
| **Grain** | A time bucket of an aggregate: hour, shift, day, week, month (and per PO). |
| **Cagg** | TimescaleDB continuous aggregate (incrementally maintained materialised view). |
| **Historian** | Long-term store: live FDW over the analytics DB + cold Parquet on S3, queried through a DuckDB-enabled Postgres gateway. |
| **Legacy / packiot40 / tsp12 / F1** | The production platform the new stack replaces and is validated against. |
| **Oracle** | The trusted reference for a comparison. Legacy **raw meters and hourly rows** are a good oracle; legacy **shift and line rows** are not (see [domain model](../understand/architecture/domain-model.md#comparing-with-legacy)). |
| **Edge box** | The on-prem machine at a factory that runs PLC readers and the Sparkplug agent (and optionally offline apps). |
| **SSM rail** | AWS Systems Manager used to reach edge boxes and hosts without inbound ports. |
| **CS Admin / csadmin** | Customer Success admin app. **customize** is its Customization Hub sibling. See [CS Admin](../understand/components/csadmin.md), [Customize](../understand/components/customize.md). |
| **Service catalog** | One row per service with its README, wiki page, API reference and dashboard. See [Service catalog](service-catalog.md). |
| **API portal** | Staging, read-only Swagger UI behind SSO at `https://api.staging.packiot.app/docs/`, with every API in one dropdown. See [API reference](api/index.md). |
| **front4** | The product web app for plant managers. **operator** is the shop-floor app. |
