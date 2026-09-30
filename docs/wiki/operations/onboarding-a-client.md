---
title: Onboarding a client
layer: 4
owner_area: frontends
last_verified: 2026-09-28
---
# Onboarding a client

> **Layer 4 · Operations** — the Customer Success procedure to bring a new factory onto the
> new stack, end to end, as CS Admin and edge-api implement it on 2026-09-28: tenant and
> hierarchy, the eight-step wizard, the per-tenant switches that make OEE compute, user
> access, and a field-by-field forms reference. For CS engineers and the developers who
> support them.
> Up: [Frontends](../subsystems/frontends.md) · Concepts: [Domain model](../architecture/domain-model.md)

!!! note "Environment"
    Everything here is the **new stack on staging** (`csadmin.staging.packiot.app`, analytics
    DB `packiot_analytics`). Production clients still run on the legacy platform; the
    wizard's last step ("Promote to production") only plans and bundles today, its apply is
    switched off.

## The idea in one paragraph

You describe the factory once, as data, and the platform generates everything else from it.
The hierarchy you build in CS Admin (enterprise → site → area → lines → machines) is composed
into the tenant's **descriptor** (a versioned JSON row in `client_descriptors`, ADR-0045),
and the descriptor is compiled into the edge config: the PLC reader's tag map, the shared
agent's tenant file and the `packml_register` topic rows. You never type a topic or a
prefix. The two values that are easy to get wrong are taken off the form: the **canonical
prefix** is derived from the enterprise, site and area names, and each machine's
**count index** (which PLC channel is its counter) is either its equipment id (when Packiot
controls the numbering) or *captured* from live data and confirmed before cutover.

## Before you start

| You need | Why | Where it comes from |
|---|---|---|
| A Cognito user in group `cs-admin` | csadmin's cross-tenant access | an existing CS admin, csadmin → Access → Login Users (type `cs`) |
| The site list, line list and machine list with the names you want in topics | names become topic segments | the client; intake template `docs/clients/bispharma-intake.md` |
| Each PLC's host/IP, protocol, rack/slot | PLC connections | the client's integrator |
| The **meaning** of each PLC register (which address is infeed, outfeed, scrap) | the tag map | the integrator's program, or the client's existing Node-RED `flows.json` (see [worked example](#worked-example-bispharma-sp)) |
| Rated speed per line (units/min) | OEE Performance | nameplate or the client |
| Shift calendar | OEE is bucketed by shift | the client |
| An on-site Linux box with Docker that reaches both the PLC network and the internet | the edge box | the client; see [First-time box setup](first-time-box-setup.md) |

Rehearse anything risky on the **sandbox twin** (enterprise 2000003, ids = CPACK + 2,000,000)
first. `scripts/provision-sandbox-tenant.sh --heal` restores it.

## Overview

```text
 A. tenant + hierarchy (csadmin forms)      B. wizard (/app/onboarding?step=…)
 ───────────────────────────────────         ───────────────────────────────────────────
 1 Enterprise  (api_key generated)           1 Set up the client box  (SSM activation)
 2 Sites       (name = prefix segment)       2 Review the plant       → descriptor v1
 3 Areas       (name = topic segment)        3 Connect the PLCs       (hosts, tag map, sensors)
 4 Lines  tp=3                               4 Set up shifts          (optional to pass)
 5 Machines tp=1 (parent line)               5 Go live (dry run)      generate → deploy → health
 6 Sectors  tp=2 (optional)                  6 Confirm counts are real (capture)
 7 Shifts, teams, targets, reasons           7 Flip it on             (readiness + cutover)
                                             8 Promote to production  (plan/bundle only)
 C. make OEE compute (per-tenant switches)   D. access: users, roles, operator container
```

Descriptor status moves `draft → generated → deployed → captured → validated → cutover`.
Reset (on the wizard page) discards generated artifacts and validation and returns to
`draft`; the authored descriptor body is kept.

## A. Create the tenant and build the hierarchy

Work top-down; each object attaches to the one above. After step 1, pick the enterprise in
csadmin's top selector: every later page is scoped to it (csadmin appends
`?idEnterprise=<selected>` to each call).

1. **Enterprise** — `/enterprises/new`. Name it as you want the **first** topic segment.
   edge-api generates `enterprises.api_key` (`randomUUID()`); that key is what factory apps
   and the box use. Note the new `id_enterprise`: the per-tenant switches in
   [section C](#c-make-oee-compute) and the operator container need it.
2. **Sites** — `/app/site`. The name is the **second** prefix segment (for example `SP`, not
   "São Paulo"). Pick a language pack (required).
3. **Areas** — `/app/area`. The name is the next topic segment (for example `LINHAS`).
4. **Lines** (tp=3) — `/app/lines`. One per production line. Overview version is required
   on create (default `v4`).
5. **Machines** (tp=1) — `/app/machines`. Each needs a parent line. The code is derived from
   the name. Set **production speed** (rated, units/min) on the machine that will be the
   line's lead (outfeed) meter.
6. **Sectors** (tp=2) — `/app/sectors`. Optional grouping; many tenants have none.
7. **Shifts** — `/app/shift` (or wizard step 4). At least one day enabled.
8. Optional now, needed before go-live: **Teams**, **Downtime reasons**, **Production
   targets** (a default target row is created automatically for each new line, see
   [section C](#c-make-oee-compute)).

The page decides the type: creating from Lines makes a line, from Machines a machine.

!!! warning "Names fold to ASCII"
    The composer strips `_`, `-` and accents (`S6_OUTPUT` → `S6OUTPUT`, `PTH40-03` →
    `PTH4003`). That is harmless for a new tenant. For a tenant that already has un-folded
    `packml_register` rows, re-deriving can insert duplicates; Review and Capture show it.

## B. Run the onboarding wizard

Open **Onboarding** (`/app/onboarding`). The active step is in the URL (`?step=boxsetup`,
`review`, `connections`, `shifts`, `golive`, `capture`, `cutover`, `promote`), so a refresh
or a shared link returns to it. A step unlocks when every step before it is complete; a
locked step shows which step to finish first. If the wizard shows a disabled panel,
edge-api has `EDGE_API_ONBOARDING_ENABLED` off.

### 1. Set up the client box

Enrol the on-site box as an AWS SSM managed instance so the cloud can reach it without any
inbound port. Check the prerequisites listed on the step, click **Mint activation**
(`POST /api/edge-ssm/activation`), run the one-time register command on the box, then
**Check connection** (it also polls `GET /api/edge-ssm/status`). The result is a managed
instance id `mi-…`. You can **Skip for now** and continue in parallel; Go live will not deploy
until the box is Online. Details: [First-time box setup](first-time-box-setup.md).

### 2. Review the plant

A read-only tree of what you built, each node showing its derived topic. Confirm the
**prefix** (derived from enterprise + site; override per site only if needed) and answer
**"Do you control this factory's PLC numbering?"**: *Yes* sets `count_index_default_mode =
equipment_id` (cutover-eligible immediately); *No* means count indices start `inferred`
and must be confirmed at Capture. **Continue** composes the descriptor (`equipment[]` from
the tree, `id_unit = id_equipment` for machines) and saves it
(`POST /api/onboarding/descriptor`). Advanced holds optional prefix fixups, metric and
parameter aliases, overrides, the tenant code (defaults to the derived one) and raw JSON.
Customizations (derive rules, Node-RED, OEE profile) are **not** here; they live in the
[Customization Hub](../components/customize.md).

### 3. Connect the PLCs

All cards edit `descriptor.plc`. A client that sends data through its own Node-RED tee has no
PLCs to declare; continue.

- **PLC connections** — one row per PLC: name, host/IP (required, with a reachability
  **Test**), protocol, optional S7 rack/slot/port/DB (defaults 0/2/102/1). A `secret://…`
  host is an unset placeholder.
- **Sensor tags (PLC tag map)** — per machine: counter **role** (net, gross, scrap), the
  **count index** (the PLC channel, not the equipment id) and the S7 address.
- **Sensor config per line** — which counters each line really has (all measured,
  outfeed only, scrap derived from infeed − outfeed, …). Advisory, but declaring it stops a
  line's scrap reading as unconfirmed later.
- **On-prem offline**, **Edge operator**, **Barcode edge** — advisory opt-ins that add a
  local decode + dashboard stack, the operator SPA, or the barcode SPA to the box so the floor
  keeps working through an internet outage (`onprem_offline`, `operator_edge`,
  `barcode_edge` on the descriptor). They do not change the cloud path.

### 4. Set up shifts

Optional to pass, **required for any OEE**: with no shift there is no window to aggregate
into and every dashboard stays blank. Enter a code, toggle weekdays and clock times, and
optionally scope to a site or area (default: plant-wide). You type clock times; the backend
stores seconds from the operational week start (see [forms reference](#shift)).
**Skip for now** is allowed but warned.

### 5. Go live (dry run)

Action-driven. **Build** calls `POST /api/onboarding/generate` (edge-api proxies to the
decoder's onboard API at `ONBOARD_GENERATE_URL`), which produces the reader profile, the
tenant file for the shared agent, `register.sql` and the tee node, then auto-applies the
register (`POST /api/onboarding/apply-register`) and validates. **Deploy** pushes the bundle
to the box over SSM (`POST /api/edge-ssm/deploy-bundle`); a green health check marks it
deployed (`mark-deployed`) and moves you to Capture. Nothing is switched onto the new tag
map yet.

A new client is **data, not infrastructure**: the generated agent file is dropped into the
**shared** multi-tenant `sparkplug-agent-shared`, and the box posts raw tags to the one
shared front door `ingest.<env>.packiot.app:8449/v1/tags` with an `X-Ingest-Key`. No new
container, DNS record or security-group rule. See [Edge](../subsystems/edge.md).

### 6. Confirm counts are real (capture)

Start a capture (`capture/start`), let live data arrive, read the report
(`capture/report`), confirm (`capture/confirm`), stop. Each counter is classified:

| Class | Meaning | Action |
|---|---|---|
| `confirmed` | observed on the configured channel | none |
| `mismatch` | seen on a different channel | fix the count index |
| `unobserved` | a sensed channel that is silent | check the sensor / PLC |
| `derived` | a counter with no reader tag (value is computed, e.g. scrap = infeed − outfeed) | expected |
| `extra` | a channel on the wire that is not in the config | usually ignore; check if it is a missed machine |

`derived` versus `unobserved` is decided by whether a tag exists, not by the machine name.
You may continue with rows still `inferred`; cutover re-checks.

### 7. Flip it on (cutover)

Two gates:

- **Hard block** (red): any count index still `inferred`. The server enforces it too
  (`onboard-gen --cutover` refuses; `POST /api/onboarding/cutover` rejects).
- **Readiness** (`GET /api/onboarding/readiness`): error-severity issues block, warnings
  advise and deep-link to the fix.

| Code | Severity | Meaning |
|---|---|---|
| `missing_ideal_speed` | error | a producing machine or line has no rated speed |
| `duplicate_equipment` | error | two active equipments with the same name and type **under the same parent line** (the same station name on different lines is fine) |
| `counter_mapping_mismatch` | error | a counter's role/channel disagrees with what was observed |
| `output_register_unobserved` | error | the line's output meter never produced data |
| `producing_without_topics` | warning | producing equipment with no active topic |
| `scrap_channel_missing` | warning | no scrap source declared |
| `no_shift_calendar` | warning | no shifts |

Cutover sets `client_descriptors.status = 'cutover'`; the agent switches from the static
tag map to the register-driven one on its next cycle, fail-safe to static on any error.
It is explicit, confirmed and reversible (Reset → draft).

### 8. Promote to production

Shows a plan (`POST /api/promote/plan`) and a downloadable bundle
(`/api/promote/bundle`) of what would be created on production. **Apply** is disabled
(`VITE_PROMOTE_APPLY_ENABLED` off in csadmin, `EDGE_API_PROMOTE_APPLY_ENABLED` off and a
not-implemented executor in edge-api). Production cut-overs follow the client-specific
runbooks in `docs/clients/` (for example `bispharma-prod-recut-runbook.md`).

## C. Make OEE compute

Cutover wires the tag map; it does not by itself make OEE right. Check each item.

1. **Shifts exist.** No shift, no OEE rows.
2. **Rated speed.** OEE Performance = actual ÷ rated. `apply-line-meters` fills any producing
   equipment that has none with `ONBOARD_DEFAULT_PRODUCTION_SPEED` (default 60); a real value
   always wins. Only the **lead machine's** `production_speed` drives a line's Performance.
3. **Line meters (line-metered tenants).** In **Lines → line configuration**, click
   **Auto-assign from sensors** (`POST /api/onboarding/apply-line-meters`). It reads each
   machine's sensor role from the descriptor (`ProdConsumedCount` = gross/infeed,
   `ProdProcessedCount` = net/outfeed), never the machine name, and fills the line's
   `gross_machine`, `lead_machine` and optional `scrap_machine`. The infeed is reliable; an
   outfeed with several candidates is a flagged guess you confirm in the dropdowns.
4. **Stream-engine tenant lists** (staging, `compose.staging.yml`, service
   `stream-engine`; each needs a deploy):

    | Variable | Add the tenant when… | Effect |
    |---|---|---|
    | `WORKER_TENANT_ALLOWLIST` | always on staging (lower-case group id) | the worker only discovers listed tenants |
    | `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` | the line has separate infeed and outfeed meters | Quality = outfeed ÷ infeed, scrap = max(gross − net, 0) |
    | `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS` | machine-metered, no state/speed signal (per equipment id) | availability from counter activity; exclusive with line-lead for the same equipment |
    | `CPAC_EVENT_LIVE_ENTERPRISES` | counters-only client with no other downtime source | live stops derived from count silence (uses each equipment's `stop_threshold_time`) |
    | `EVENTS_CLOSE_STALE_ENTERPRISES` | always, if you add the tenant to a CPAC deriver list | closes never-ended stops |

    The OEE skeleton rows are provisioned for every equipment (`RUNTIME_PROVISION_ENABLED`);
    `BAKE_ENTERPRISE_IDS` no longer gates OEE (it only feeds an identity sentinel check).
5. **Thresholds.** New equipment defaults to running ≥ 85 % and stopped < 30 % of rated
   speed (csadmin form, edge-api create, and an analytics backfill). NULL thresholds grey
   out the Mission Control timeline.
6. **Targets.** A trigger (`config.piot_seed_line_default_target`, migration
   `t-backfill-production-targets-default`) seeds a `config.production_targets` row for each
   new line: `vl_hour = round(lead speed × 0.85)` (the 85 % world-class OEE benchmark), shift,
   day, week, month derived. The set-target API only updates existing rows, which is why
   the seed matters. CS can override per line on **Production Targets**.

**Verify** in the analytics DB (CloudBeaver at `db.staging.packiot.app`):

```sql
-- hierarchy
SELECT id_equipment, nm_equipment, tp_equipment, id_parentequipment, production_speed
FROM equipments WHERE id_enterprise = <id> ORDER BY tp_equipment DESC, nm_equipment;
-- routing
SELECT count(*) FILTER (WHERE active) AS active_topics FROM packml_register
WHERE id_equipment IN (SELECT id_equipment FROM equipments WHERE id_enterprise = <id>);
-- OEE is computing (0 rows = a gate above is missing; start with shifts)
SELECT count(*) FROM equipment_oee_shift r JOIN equipments e USING (id_equipment)
WHERE e.id_enterprise = <id>;
```

The go / no-go bar is `docs/clients/onboarding-acceptance-checklist.md` (8 gates, each with a
probe). **"Bispharma-clean"** = every gate green and **zero clamps** firing (no totalizer
spike clamp, no net > gross, no OEE factor out of range). "Wired but dirty" (Gate 5
counters red) is a no-go: data flows but cannot be trusted.

## D. Give people access

| Who | What to create | Where |
|---|---|---|
| Client managers (front4) | Cognito user (type `client`) + `identity.users` row with a role whose `permissions.desktop.line` lists the lines and `desktop.screen` the pages | csadmin **Login Users** (creates both, born-linked), then **Users & Roles** / **Roles** |
| Operators | same, and `identity.users.user_name` must equal the email (operator login looks it up by `user_name`) | csadmin |
| The operator app for this tenant | a new operator container + vhost + keys: `OPERATOR_<X>_EDGE_API_KEY` (the tenant's `enterprises.api_key`) and a read key in read-api `QUERY_API_KEYS` | stack PR (copy `operator-bispharma`), `/opt/packiot/.env` |
| Box scanning | on-prem `barcode_edge` opt-in (step 3), or a cloud barcode instance with the tenant's key | [Barcode app](../components/barcode-app.md) |
| CS engineers | Cognito user type `cs` (joins `cs-admin`) | csadmin **Login Users** |

A role with an empty line list makes front4 load a blank workspace; read-api caches
identity per token, so restart read-api after fixing a role. See
[Identity](../subsystems/identity.md#failure-modes-signals).

## Worked example: Bispharma SP

Bispharma (enterprise 5) has two sites, `SP` and `Bisnago`, on separate subnets. SP has 16
lines, one S7 PLC each; a line is six stations (`S1INFEED · S3 · S4 · S5 · S6OUTPUT ·
SCRAP`) whose counters are a packed array of 32-bit `DINT` totalizers in `DB1`. The
hierarchy gave the prefix `BISPHARMASTAGING/SP/LINHAS/...` without anyone typing it.

**The wire gives you syntax, never semantics.** You can read that a register climbs about
1.2/s; you cannot read that it is "good units off the filler". Harvest the mapping from the
factory's existing Node-RED `flows.json` (S7 endpoint, variable list, and the function node
that names each counter). For SP line L01:

| S7 address | Modbus mirror | Machine | Role |
|---|---|---|---|
| `DB1,DINT0` | `HR[0:1]` | S1INFEED | gross / infeed (`ProdConsumedCount`) |
| `DB1,DINT4` | `HR[2:3]` | (S2, no equipment) | scrap subtrahend only |
| `DB1,DINT8` | `HR[4:5]` | S3 | intermediate station |
| `DB1,DINT12`, `DINT16` | `HR[6:9]` | S4, S5 | intermediate |
| `DB1,DINT20` | `HR[10:11]` | S6OUTPUT | net / outfeed (`ProdProcessedCount`) |
| `DINT0 − DINT4` | — | SCRAP | scrap (`ProdDefectiveCount`) |

!!! danger "The mapping that looks right and is wrong"
    Sampling live shows two moving counters, `HR[0:1]` and `HR[4:5]`, which invites
    "infeed + output". `HR[4:5]` is S3, an intermediate station: it counts faster than the
    infeed, which a real output on a serial line cannot do (net ≤ gross), and the unread gap
    at `HR[2:3]` is exactly the scrap subtrahend. Wiring S3 as output manufactures
    Quality > 100 %.

Other lessons from this onboarding: the PLC also served Modbus TCP as a mirror of `DB1`
(byte offset B = holding register B/2), so use whichever protocol the box can reach; L01
exposes no state or speed, so OEE is counters-only (emit counts, do not invent a state
signal), which is why Bispharma is in `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES` and
`CPAC_EVENT_LIVE_ENTERPRISES`; bulk-imported lines had no target rows until the 2026-09-22
backfill; and a Bispharma user needs the `operator-bispharma` container, not CPACK's
(2026-09-24). Compare totalizers by **increments**, never absolute values: PLCs reset on
different dates.

## Forms reference

Required/optional comes from the Zod schemas in `csadmin/src/schemas/index.ts` (they gate
Save) and defaults from each page's default values. 🔴 required, empty by default · 🟡
required, pre-filled · ⚪ optional.

### Enterprise

| Field | State | Column | Notes |
|---|---|---|---|
| Name | 🔴 | `nm_enterprise` | first topic segment |
| Timezone | 🟡 `America/Sao_Paulo` | `timezone` | |
| Scrap calc type | 🟡 `1` | `scrap_calc_type` | 0–2 |
| Week begin / day begin / week size | 🟡 `0` / `0` / `604800` | `week_begin`, `day_begin`, `week_size` | raw seconds; shown as weekday + time (see below) |
| Logo, Active | ⚪ | `logo`, `active` | |

`api_key` is generated server-side; you never enter it.

### Site

| Field | State | Column | Notes |
|---|---|---|---|
| Name | 🔴 | `nm_site` | second prefix segment |
| Language pack | 🔴 (empty default) | `language_tag` | blocks Save until chosen |
| Timezone | 🟡 `America/Sao_Paulo` | `timezone` | |
| Week fields | 🟡 `0` / `0` / `604800` | `week_*` | |
| Active | ⚪ | `active` | |

### Area

| Field | State | Column | Notes |
|---|---|---|---|
| Name | 🔴 | `nm_area` | topic segment |
| Site | 🔴 | `id_site` | |
| Week fields | 🟡 | `week_*` | |
| Active | ⚪ | `active` | |

### Equipment (line tp=3, machine tp=1, sector tp=2)

| Field | State | Column | Notes |
|---|---|---|---|
| Name | 🔴 | `nm_equipment` | code derived from it on create (`cleanCode`, e.g. "Cerâmica 400" → `CER400`) |
| Code | 🟡 (derived) | `cd_equipment` | required; not re-derived on edit |
| Site, Area | 🔴 | `id_site`, `id_area` | |
| Parent line/sector | 🔴 machine, on create | `id_parentequipment` | |
| Overview version | 🔴 line, on create (default `v4`) | `overview_version` (jsonb) | sent as `JSON.stringify([{version}])` |
| Mirrored machine | 🔴 sector, on create | `id_equipment_status_mirror` | |
| Downtime threshold (s) | 🟡 `60` | `stop_threshold_time` | below = micro-stop, above = downtime |
| Production speed (units/min) | 🟡 `0` | `production_speed` | rated speed; **set it** on the lead machine |
| Ideal speed | ⚪ | `ideal_speed` | |
| Min performance threshold (% of rated) | 🟡 `30` | `minimum_performance_threshold` | below = stopped (also PLC param 30750) |
| Min ideal performance threshold (%) | 🟡 `85` | `minimum_ideal_performance_threshold` | at/above = running; between = low speed |
| Require downtime reason | 🟡 `true` | `require_downtime_reason` | |
| Event should be displayed | 🟡 `true` | `event_should_be_displayed` | |
| Status type | 🟡 `5` | `status_type` | event trigger: 0 instant, 5 five-minute average (CPAC), 1 rare |
| Net production type | 🟡 `0` | `net_production_type` | 0 sensors, 1 scanned boxes |

Structural fields (parent, overview version, mirror) are enforced on **create only**: the
migration left many existing rows NULL and requiring them on edit made those rows
uneditable. Removed from the form, columns kept: `id_plc`, `use_label_net_production`,
`speed_calculated_by_packiot`, `event_generated_by_packiot`, `id_counter_status`.

### Shift

| Field | State | Column | Notes |
|---|---|---|---|
| Name/code | 🔴 | `shifts.cd_shift` | alphanumeric |
| Days | 🔴 at least one on | one `shift_hours` row per enabled day | start/end as `HH:MM` |
| Sequence position | 🟡 `1` | `sequence_position` | ordering |
| Site / Area | ⚪ | `id_site` / `id_area` | area first, site fallback |
| Active | ⚪ | `active` | |

### Other forms

| Form | Required fields |
|---|---|
| PackML register (manual) | site, area, equipment; edit: topic, equipment, active |
| Team | `cd_team` (sequence, site, area, equipment default 0) |
| Production target | `vlHour`, `vlDay`, `vlWeek`, `vlMonth` (≥ 0), scrap day default 0 |
| User | name, valid email, role, active |
| Role | `nm_user_role` |
| Language pack | `language_tag` (e.g. `pt-BR`) |
| Descriptor profile (Review → Advanced) | tenant code, canonical prefix |

### Week fields and shift times

`week_begin`, `day_begin` and `week_size` are signed **seconds** from the operational week
start (CPACK's `week_begin` is `-3000`, Sunday 23:10). The form shows weekday + time and
converts on save (`csadmin/src/lib/shift-time.ts`, `week-fields.ts`); an untouched value
round-trips exactly (an untouched `-3000` is not rewritten to `601800`). Shift
`begin_time`/`end_time` are seconds from `week_begin`, day 1 = Monday … 7 = Sunday.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Wizard shows a disabled panel | `EDGE_API_ONBOARDING_ENABLED` off | enable on edge-api |
| Every csadmin call 401 | missing Cognito build args, or user not in `cs-admin` | [CS Admin](../components/csadmin.md#failure-modes) |
| Line create 500 | overview version sent as an array | current csadmin sends a JSON string |
| Review stuck on "equipment exists" | no machines under the lines | build the hierarchy first |
| Capture shows everything `unobserved` | reader not deployed or box offline | Go live health, Box Ops logs |
| Cutover blocked `missing_ideal_speed` | lead machine has no speed | set `production_speed`, or run apply-line-meters |
| Cut over, but 0 OEE rows | no shifts; tenant missing from `WORKER_TENANT_ALLOWLIST` | section C |
| Mission Control grey | NULL thresholds | defaults 30/85 |
| Targets empty in csadmin | line created before the target trigger | re-run the backfill migration or create targets |
| Client user sees an empty front4 | not linked, or role without lines | [Identity](../subsystems/identity.md) |

## Related

- [First-time box setup](first-time-box-setup.md) · [Edge](../subsystems/edge.md) ·
  [CS Admin](../components/csadmin.md) · [Customization Hub](../components/customize.md)
- [Domain model](../architecture/domain-model.md) (hierarchy, counters, OEE)
- ADRs: `docs/adr/0045-client-onboarding-architecture.md`,
  `docs/adr/0058-client-customization-capability.md`
- Client material: `docs/clients/` (Bispharma intake, descriptors, runbooks, acceptance
  checklist)
