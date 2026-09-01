# Onboarding a Client

The end-to-end process a CS engineer follows to bring a new factory onto Packiot, done
through **CS-Admin** (`csadmin.<env>.packiot.app`). Onboarding writes land in the
**`packiot_analytics`** (F3) plane.

## The big idea (ADR-0045): compose from the hierarchy

The onboarding wizard **generates the edge config from the equipment hierarchy you
build** — you do *not* hand-author topics or a routing prefix. Build the tree with the
right **codes/names**, and the wizard composes the descriptor (the single source of
truth) from it. The two hardest, easiest-to-get-wrong values leave the authoring
surface entirely:

- **Canonical prefix** — *derived* from the enterprise + site codes (folds `C-PACK`→`CPACK`),
  shown as a confirmable line. Every topic is composed from it, so the generate-time
  `HasPrefix` check can't be violated by construction.
- **Count index** — never typed. One toggle: *"Do you control this factory's PLC
  numbering?"* → `equipment_id` mode (cutover-eligible now) vs inferred-then-captured.

## Step 0 — build the hierarchy (before the wizard)

Create these in order (each attaches to the one above; the currently-selected
enterprise in the top-of-app selector is the scope):

| Order | Entity | Page | Notes |
|-------|--------|------|-------|
| 1 | **Enterprise** | Enterprises | auto-generates `api_key`. Name = 1st prefix segment. |
| 2 | **Site** | Sites | Name = 2nd prefix segment (the `code` field is **phantom — not saved**, so *name it* what you want the segment to be, e.g. `SP`). Pick a language pack. |
| 3 | **Area** | Areas | Name = topic segment (same phantom-code rule → name it `LINHAS` etc.). |
| 4 | **Lines** (`tp=3`) | Lines | one per production line. `overview_version` (v4) required for lines. |
| 5 | **Machines** (`tp=1`) | Machines | each requires a **parent line**. Code auto-derives from the name. This is where `status_type` / counter-role calls matter (see [Concepts](08-concepts.md)). |
| 6 | **Sectors** (`tp=2`) | Sectors | optional grouping layer; many tenants have none. |
| 7 | **Shifts** | Shifts | `cd_shift` + ≥1 day enabled; sets the OEE time buckets. |

> **Type is fixed by the page.** Creating from Lines makes a Line, from Machines a
> Machine — the type is a read-only indicator, not a switcher.

> **Naming folds to ASCII.** The composer strips `_`/`-` and accents (`S6_OUTPUT`→`S6OUTPUT`,
> `PTH40-03`→`PTH4003`). Harmless for greenfield (self-consistent); for a tenant with an
> existing un-folded `packml_register`, re-derivation could double-insert — Review +
> Capture catch it, and raw-JSON is the escape hatch.

Field-by-field detail for every form → **[CS-Admin Forms Reference](03-csadmin-forms.md)**.

## The 5-step wizard (Onboarding page)

Once the hierarchy exists, the wizard walks five client-outcome steps:

### 1. Review the plant
Read-only tree of the sites/areas/lines/machines you built, with each node's **derived
canonical topic** shown as helper text. Confirm it looks right; on continue it
**composes the descriptor** (`equipment[]` from the tree, `id_unit=id_equipment` for
machines) and upserts it. The **prefix** is derived here; the **count-index toggle**
lives in this step's Advanced drawer.

### 2. Connect the PLCs
Author the PLC endpoint(s) — the host/protocol per PLC. This is where the actual PLC
connection lives (not the vestigial `id_plc` field). Three cards, in order: the endpoint
host/IP (with a reachability **Test**), the per-machine **tag map** (endpoint + count-index
+ role), and **"Which sensors does each line have?"** — the per-line sensor situation
(`counter_derive`: all measured / outfeed-only / scrap-derived-from-infeed−outfeed / …).
Declaring the sensor situation here, rather than letting a default stand, is what avoids a
line's scrap silently reading as unconfirmed later.

### 3. Go live (dry run)
**Build & deploy the edge** in one action: generate the bundle (`onboard-gen` → profile
+ agent.yaml + register.sql + tee-node.json), auto-apply the register, then deploy to
the client's box. Nothing is switched onto the new routing yet — this just gets data
flowing so the next step can confirm counts. Artifact code panels + the runner/download
fallback live in Advanced.

### 4. Confirm counts are real (Capture)
For each machine, confirm its **channel number** (count-index) against a **live
observation** from the tee. The PLC's count channel is arbitrary and not derivable — it
must be captured, machine by machine. A `confirmed` capture gates cutover; `inferred`
guesses do not.

### 5. Flip it on (Cutover)
The server-enforced cutover gate flips the tenant onto the register-driven tag map. Two
gates are shown with distinct visual language: an **amber advisory** (ADR-0047 readiness,
"worth checking") and a **red hard-block** (any count-index still inferred → "required").
The flip is explicit, confirmed, and reversible — never auto-advanced.

## What "cutover" actually means (two mechanisms)

1. **Generation-time gate** — `onboard-gen --cutover` refuses to emit if any member's
   count-index is still `inferred`. *"No tenant cuts over on inferred data."*
2. **Runtime per-tenant flip** — the agent reads `client_descriptors.status`; when
   edge-api sets it to `'cutover'`, the agent switches from the static tag map to the
   register-driven one. The flip state is **data owned by edge-api**; the agent reads
   it, fail-safe to static on any error.

## After cutover: making OEE actually compute (the three tenant gates)

**A fully-onboarded, cutover tenant can still show ZERO OEE.** Cutover only flips the
tag map — it does **not** wire the tenant into the analytics OEE pipeline. Three
separate per-tenant gates must **all** include the new `id_enterprise`, or the numbers
stay silently empty (raw counts flow, but no `equipment_runtime_shift` rows exist).
Check them in this order:

1. **Shifts** — onboarding step 5 of the hierarchy is *shifts*, and it is load-bearing:
   with no `shifts` / `shift_hours` there is no shift window, so **nothing** aggregates.
   Set them on the CS-Admin Shifts page (or `POST /api/shifts/create` + 7×
   `/api/shift-hours/create`; `shift_hours.begin_time/end_time` are **seconds from
   Monday 00:00**). A tenant reaching `validated` with 0 shifts is an incomplete
   onboarding — the readiness gate should assert this.

2. **`BAKE_ENTERPRISE_IDS`** (stream-engine env) — the runtime-provision
   (`provision.go`, the `piot_create_*_runtime` fns) that **creates** each tenant's
   `equipment_runtime_shift` skeleton rows only runs for enterprises in this CSV. The
   base rollup then only fills rows flagged `recalc_needed`, so **with no skeletons,
   nothing computes.** Add the new id here (e.g. `"3,4"` → `"3,4,5"`) and redeploy —
   provision creates the skeletons on boot. **This is the master gate for the OEE
   surface.**

3. **The meter model** — how the line derives gross/net/scrap:
   - **Line-metered** (separate infeed + outfeed machines, e.g. bispharma): set
     `COUNTERS_ONLY_LINE_LEAD_ENABLED=true` + the id in `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES`.
     The tp=3 line row names `gross_machine` (infeed), `lead_machine` (outfeed/net) and
     optional `scrap_machine`; stream-engine `line_lead` computes **Quality = net/gross =
     outfeed/infeed** and **scrap = GREATEST(gross − net, 0)** — no reject meter needed.
   - **Machine-metered** (both meters on one machine, or single-sensor machines, e.g.
     CPACK): use `COUNTERS_ONLY_AVAILABILITY_*` instead. The two are **mutually
     exclusive per enterprise**.

### Designating a line's infeed/outfeed meters
For a line-metered tenant, tell each line which member is its infeed vs outfeed. In
**CS-Admin → Line configuration**, click **"Auto-assign from sensors"** — it derives
the meters from each machine's **sensor role** (decoded from the SparkPlug metric name,
`ProdConsumedCount`=gross/infeed, `ProdProcessedCount`=net/outfeed), **never the machine
name** (client naming isn't portable). It nails the infeed reliably; where a line has
several outfeed candidates the outfeed is a flagged **guess** you confirm in the same
per-line dropdowns. Runs the `POST /api/onboarding/apply-line-meters` endpoint —
descriptor-driven, so it survives a re-onboard.

> **Verify OEE is computing:** `SELECT count(*) FROM equipment_runtime_shift r JOIN
> equipments e ON e.id_equipment=r.id_equipment WHERE e.id_enterprise=<id>;` — zero rows
> means one of the three gates above is unset (start with `BAKE_ENTERPRISE_IDS`).

## Which plane / how to verify

Onboarding writes go to **`packiot_analytics`**. To confirm a write landed, query that
DB (via the staging app box):

```sql
-- enterprises use nm_enterprise (no cd_ column); sites/areas likewise nm_*
SELECT id_enterprise, nm_enterprise FROM enterprises WHERE nm_enterprise ILIKE '%<name>%';
SELECT id_site, nm_site, language_tag, week_begin, day_begin, week_size FROM sites WHERE id_enterprise = <id>;
```

New-stack tenants use a `+2,000,000` id offset on staging (e.g. site id `2000007`).

## Related

- The descriptor / config-as-data model in depth → **[Edge & Ingestion](04-edge-and-ingestion.md)**
- Why count-index ≠ id_equipment (the #601 bug) → **[Concepts](08-concepts.md)**
