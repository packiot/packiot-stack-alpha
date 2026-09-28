---
title: Glossary
layer: 0
owner_area: platform
last_verified: 2026-09-28
---
# Glossary

> **Layer 0 · Start here.** Terms used across the wiki, with a link to where each is
> explained in depth. Up: [Home](index.md)

## Manufacturing and OEE

| Term | Meaning | More |
|---|---|---|
| **OEE** | Overall Equipment Effectiveness = **A × P × Q**. The share of planned production time spent making good product at ideal speed. | [Domain model](architecture/domain-model.md#oee) |
| **Availability (A, `oee_a`)** | running time ÷ planned production time (available time). | [Domain model](architecture/domain-model.md#oee) |
| **Performance (P, `oee_p`)** | actual output ÷ output at ideal speed over the running time. Stored as the residual that closes oee = a·p·q. | [Domain model](architecture/domain-model.md#oee) |
| **Quality (Q, `oee_q`)** | net (good) ÷ gross (total). | [Domain model](architecture/domain-model.md#oee) |
| **Planned downtime** | Stops that are scheduled (lunch, planned maintenance, no order). Removed from the Availability denominator. | [Domain model](architecture/domain-model.md#time-model) |
| **Gross / net / scrap** | gross = units consumed (input), net = good units produced (output), scrap = gross − net. | [Domain model](architecture/domain-model.md#counters) |
| **Consumed / Processed / Defective count** | PackML counter names on the PLC for gross, net and scrap. | [Domain model](architecture/domain-model.md#counters) |
| **Ideal speed** | Rated units per minute (`production_speed`, PackML parameter 30701). | [Domain model](architecture/domain-model.md#oee) |
| **Production order (PO / OP)** | A job to make N units of a product on a line. Lifecycle: available → running → paused → finished. | [Domain model](architecture/domain-model.md#production-orders) |
| **Shift** | A named working period (e.g. 06:30–15:00). Shift hours are stored as seconds from `week_begin`. | [Domain model](architecture/domain-model.md#time-model) |
| **Downtime / event** | A state interval (running, stopped, planned stop…) for a machine or line; operators justify stops with a reason code. | [Domain model](architecture/domain-model.md#events-and-downtime) |
| **Box / label scan** | A packed box whose barcode (`op;number;quantity`) is scanned by the barcode app; samples are counted separately. | [Barcode app](components/barcode-app.md) |

## Equipment and tenancy

| Term | Meaning |
|---|---|
| **Enterprise** | A client company (the tenant). CPACK = analytics enterprise **3** (legacy **1**); Bispharma = **5**; Incoplast = **4**; the CPACK sandbox twin = **2000003**. |
| **Site / area** | Plant / section of a plant. Hierarchy: enterprise → site → area → equipment. |
| **Equipment, `tp_equipment`** | 1 = machine, 2 = sector, 3 = line. |
| **Lead machine** | The machine whose signals stand for a line's availability and events (PackML parameter 30702). |
| **Line-lead** | Deriving a line's counters and availability from its member machines (`gross_machine`, `net_machine`, `lead_machine`). See [stream-engine](components/stream-engine.md). |
| **Counters-only client** | A factory whose PLCs send counts but no machine state; availability is derived from count activity. |
| **Sandbox / twin** | Tenant 2000003: a resettable copy of CPACK used for tests and rehearsals (ids offset by 2,000,000). |
| **Tenant fence** | Server-side rule that every read/write is scoped to the caller's enterprise, resolved from its credential, never from the request. See [Tenancy & security](architecture/tenancy-and-security.md). |

## Platform

| Term | Meaning |
|---|---|
| **Sparkplug B** | MQTT payload convention used between the factory and the cloud (birth/death certificates, metric aliases). |
| **PackML** | ISA-TR88 naming for machine states and counters; Packiot uses PackML parameter ids (30700–30899). |
| **Topic routing / `packml_register`** | Map from a Sparkplug topic to an `id_equipment`. |
| **Medallion** | The analytics DB's layering: **bronze** (raw as received) → **silver** (cleaned facts) → **gold** (OEE grains) → **serving** (API-shaped functions/views). |
| **Grain** | A time bucket of an aggregate: hour, shift, day, week, month (and per PO). |
| **Cagg** | TimescaleDB continuous aggregate (incrementally maintained materialised view). |
| **Historian** | Long-term store: live FDW over the analytics DB + cold Parquet on S3, queried through a DuckDB-enabled Postgres gateway. |
| **Legacy / packiot40 / tsp12 / F1** | The production platform the new stack replaces and is validated against. |
| **Oracle** | The trusted reference for a comparison. Legacy **raw meters and hourly rows** are a good oracle; legacy **shift and line rows** are not (see [domain model](architecture/domain-model.md#comparing-with-legacy)). |
| **Edge box** | The on-prem machine at a factory that runs PLC readers and the Sparkplug agent (and optionally offline apps). |
| **SSM rail** | AWS Systems Manager used to reach edge boxes and hosts without inbound ports. |
| **CS Admin / csadmin** | Customer Success admin app. **customize** is its Customization Hub sibling. |
| **front4** | The product web app for plant managers. **operator** is the shop-floor app. |
