# Concepts & Glossary

The vocabulary you need to read the rest of the wiki and the code.

## OEE = Availability × Performance × Quality

The platform's headline metric. Each factor:

| Factor | Formula | Source |
|--------|---------|--------|
| **Availability** | `running_time / (total_time − planned_downtime)` | `equipment_events` overlaps where PackML `status = 6` |
| **Quality** | `net / gross` | good count / total processed count |
| **Performance** | `oee / (A × Q)` — **back-solved residual** | never measured directly |
| **OEE** | `net / ideal_production` | composite |

Performance being a residual is a known weakness (ADR-0037): a mis-set `ideal_speed`
inflates it. Bounded by the Silver clamp + `data_quality_event` tripwires.

## count_index (the #601 concept)

The integer a PLC embeds in a count topic: `.../ProdProcessedCount/<idx>/Unit`. It
identifies **which physical PLC counter channel** emitted the count. It is **arbitrary,
factory-chosen, and not derivable from any table** — CPACK's BREYER has `id_equipment=53`
but emits on channel `61`. Conflating it with `id_equipment` synthesizes allowlist
entries the PLC never sends → 0 counts. It must be **captured from a live tee**, per
member, tagged `confirmed|inferred`; no tenant cuts over on `inferred`.

## The canonical topic shape

```
<ENTERPRISE>/<SITE>/<AREA>/<LINE>[::<SECTOR>][/<MACHINE>]/<METRIC_LEAF>
└── ASCII, UPPERCASE, no accents, no hyphens, no zero-padding ──┘
```
`packml_topic` = topic minus the metric leaf (and any `/idx/Unit`). The cloud resolver
maps `packml_topic → id_equipment` with a **shortest-topic tie-break**, scoped by
enterprise (the cross-tenant guard).

## PackML parameters (SparkPlug B)

| ID | Meaning |
|----|---------|
| 30700 | Machine sequence (startup config; looked up via `id_unit`) |
| 30701 | Ideal speed |
| 30702 | Lead machine (`id_equipment` that generates line downtimes) |
| 30750 / 30751 | Min speed threshold / min threshold time |
| 30758 | Event trigger type: 0=instant, **5**=5-min average (CPAC). *(Docs long said "4"; the value in real data is 5.)* |
| 30800–30899 | Production order control (start/stop/setup) |

## Week-encoding (shifts)

`shift_hours.begin_time`/`end_time` = **integer seconds from the operational week start**,
not clock times (`21600` = 06:00). `week_begin` = **signed** offset from Monday 00:00,
**can be negative** (CPACK `-3000` = the week starts Sunday 23:10). csadmin shows these as
weekday+time pickers and converts; storage stays raw seconds.

## Shared multi-tenant ingest (ADR-0047)

The cloud `sparkplug-agent` is **multi-tenant**: **one process serves N tenants**, each an
isolated pipeline (own alias space, own outbox, own uplink) keyed by the SparkPlug
**`group_id`**. There is **one shared, tenant-agnostic front-door** —
`ingest.<env>.packiot.app:8449` — that forwards every `POST /v1/tags` to the shared agent,
which routes each envelope by its declared `group` (missing/unknown group → **403**). A
`X-Ingest-Key` header authenticates; tenant isolation is the group-routing + per-box SG /32,
not the key. **A new client is a generated tenant config file, not new infrastructure** —
no new container, nginx block, DNS record, or SG rule. The agent also has a single-file mode
(`AGENT_CONFIG`) for the legacy one-agent-per-client deployments; the register-cutover flip
and live-capture posture are single-file-only. See [Edge & Ingestion](04-edge-and-ingestion.md).

## The descriptor (config-as-data, ADR-0045)

One CS-Admin-authored YAML per tenant = the single source of truth. `onboard-gen`
generates the profile, `packml_register` SQL, agent config, and Node-RED tee snippet from
it. Raw→canonical quirks are absorbed stack-side (`prefix_fixups`, `metric_aliases`,
`parameter_aliases`). The generated register SQL also backfills `id_site`/`id_area` onto each
`packml_register` row from `equipments` — a NULL there makes the topic read as "not
registered" and the tenant's counts are silently dropped.

## Coded field values (the enum reference)

Many columns store a bare integer. The meanings (verify option labels against
`csadmin/src/pages/equipment-form.tsx` constants + edge-api semantics):

| Field | Value → meaning |
|-------|-----------------|
| **tp_equipment** | 1 = Machine · 2 = Sector · 3 = Line |
| **production_orders.status** | 1 = available · 2 = running · 3 = finished · 4 = paused |
| **status_type** (event trigger, PackML 30758) | 0 = instant · **5** = 5-min average (CPAC) · 1 = rare/unconfirmed. Real data uses **0 / 1 / 5** — the "4" older docs assumed is never used in any tenant. |
| **net_production_type** | 0 = from sensors · 1 = from scanned boxes |
| **id_counter_status** | **dead column** — NULL on every equipment in both DB planes, no reader anywhere; removed from the form (column kept). |
| **scrap_calc_type** (enterprise) | 0 / 1 / 2 *(per-tenant scrap semantics)* |
| **overview_events_type** | derived from type: line = 3 · sector = 2 · machine = 1 |
| **client_descriptors.status** | draft → generated → captured → validated → cutover |
| **count_index.confidence** | inferred (blocks cutover) · confirmed |

> These enums are the target of the **form-readability** work — the goal is that every
> such dropdown shows the *meaning*, never a bare number. This table is the canonical
> source for those labels.

## lead_machine, gross_machine, scrap_machine

For a line (`tp=3`), OEE rolls up from member machines. `lead_machine` = the machine
whose SparkPlug events generate the line's downtimes (default = first machine).
`gross_machine`/`scrap_machine` name the counter-role sources for the line's OEE, with the
identity `gross = net + scrap` filling any NULL.

## SparkPlug B aliases / BIRTH

DATA references each metric by a `uint64` **alias** bound only in the retained **NBIRTH**;
a missed BIRTH makes every NDATA undecodable until a rebirth. Aliases are scoped per
publisher. The rebirth machinery (retained NBIRTH, seq-gap detection, NCMD, brand-new-tag
rebirth) exists to prevent exactly that.

## The two planes

`packiot` (F1, legacy) vs `packiot_analytics` (F3, live). CS-Admin/onboarding writes land
in `packiot_analytics`. See [Database](06-database.md).
