# CS-Admin Forms Reference

Every onboarding form, field by field — required vs optional, the DB column it maps to,
and the traps. The required/optional split comes straight from the Zod schemas in
`csadmin/src/schemas/index.ts` (those gate the Save button); the form UI marks required
fields with a red `*` and tucks optional ones into an "Optional settings" drawer.

Legend: 🔴 **must-have** (empty by default → Save disabled) · 🟡 **required but
pre-filled** (has a sensible default) · ⚪ **optional**.

## Enterprise
| Field | State | Maps to | Notes |
|-------|-------|---------|-------|
| Name | 🔴 | `enterprises.nm_enterprise` | 1st prefix segment |
| Timezone · Scrap-calc type · Week begin/day/size | 🟡 | `timezone`, `scrap_calc_type`, `week_*` | week fields are human-readable pickers (see below) |
| Logo · Active | ⚪ | `logo`, `active` | |

## Site
| Field | State | Maps to | Notes |
|-------|-------|---------|-------|
| Name | 🔴 | `sites.nm_site` | **drives the prefix segment** (the `code` field is phantom — name it `SP`, not "São Paulo") |
| Language pack | 🔴 | `sites.language_tag` | `min(1)` with empty default → blocks Save |
| Timezone · Week begin/day/size | 🟡 | `timezone`, `week_*` | |
| Active | ⚪ | `active` | |

## Area
| Field | State | Maps to | Notes |
|-------|-------|---------|-------|
| Name | 🔴 | `areas.nm_area` | topic segment |
| Site (parent) | 🔴 | `areas.id_site` | select |
| Week begin/day/size | 🟡 | `week_*` | |
| Active | ⚪ | `active` | |

## Equipment — Line (`tp=3`) / Machine (`tp=1`) / Sector (`tp=2`)
Created from the Lines / Machines / Sectors page respectively; **type is fixed by the
page** (read-only). Code **auto-derives from the name** (`cleanCode`) — you never type it.

| Field | State | Maps to | Notes |
|-------|-------|---------|-------|
| Name | 🔴 | `nm_equipment` | code auto-derived |
| Site · Area | 🔴 | `id_site`, `id_area` | select |
| Parent line/sector | 🔴 *(machine only)* | `id_parentequipment` | superRefine blocks Save until picked |
| Overview version | 🔴 *(line only, pre-filled `v4`)* | `overview_version` (jsonb) | required for lines |
| Mirrored machine | 🔴 *(sector only)* | `id_equipment_status_mirror` | |
| Downtime threshold `60` · Production speed `0` · Min-perf `40` · Min-ideal-perf `35` · status_type `4` · id_counter_status · net_production_type | 🟡 | resp. columns | OEE-relevant; review per machine (see [Concepts](08-concepts.md)) |
| ideal_speed | ⚪ | `ideal_speed` | |

## Shift
| Field | State | Maps to | Notes |
|-------|-------|---------|-------|
| Name/code | 🔴 | `shifts.cd_shift` | alphanumeric |
| ≥ 1 day enabled | 🔴 | `shift_hours` rows | superRefine |
| Sequence position `1` | 🟡 | `sequence_position` | |
| Site / Area scope | ⚪ | `id_site` / `id_area` | area-first, site fallback |

## Human-readable week fields

`week_begin` / `day_begin` / `week_size` are stored as **raw operational seconds**
(signed offsets; `week_begin` can be negative — CPACK is `-3000` = Sunday 23:10). The
form shows them as **weekday + time / time / days** and converts on write, reusing
`csadmin/src/lib/shift-time.ts`. A **round-trip guard** preserves the exact stored value
when unchanged (an untouched `-3000` is never gratuitously rewritten to its congruent
`601800`). An "Advanced: raw seconds" escape hatch remains for exotic offsets. Storage +
the edge-api DTO are unchanged — this is pure UI.

## Phantom & removed fields (know these)

- **`code` on Enterprise/Site/Area is phantom** — there is no `cd_enterprise`/`cd_site`/
  `cd_area` column; the write path drops it. The domain `code` *type* survives only
  because the prefix-derivation reads it as a fallback. The blank inputs were removed.
- **Removed as dead** (form-only; DB columns kept): `id_plc` (no PLC registry exists;
  PLC config lives in the descriptor `plc:` blocks), `use_label_net_production` (dead
  duplicate of the live `net_production_type`), and the zero-reader legacy flags
  `speed_calculated_by_packiot` / `event_generated_by_packiot`.
- **Kept — verified live readers:** `net_production_type` (OEE quality branch),
  `overview_version` (F3 view expands it), `event_should_be_displayed`,
  `require_downtime_reason`, `ideal_speed`+`production_speed`.
- **Deliberately untouched (collision-sensitive):** `id_counter_status`, packml
  `id_infeedcounter`/`id_outfeedcounter` — the counter-role columns from the Phase-9
  collision incident.

## A gotcha worth remembering

`overview_version` is a **jsonb** column. csadmin sends it as a JSON *string*
(`JSON.stringify([{version:"v4"}])`) so edge-api binds it as text and Postgres coerces
to jsonb — sending a raw JS array serializes as Postgres `text[]` and 500s every line
create. (Fixed in csadmin #62; the durable follow-up is edge-api casting its jsonb
columns explicitly.)
