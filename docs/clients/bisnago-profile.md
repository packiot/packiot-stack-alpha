# Bisnago — client onboarding PROFILE (reverse-engineered from the legacy Node-RED flow)

**Source of truth:** the legacy bisnago Node-RED flow (70 nodes: 19 `s7 endpoint` +
7 `s7 in` + 25 `function` + 1 GCP PubSub out to
`projects/packiot/topics/bispharma_bisnago_publisher`). Every fact below is tagged
**CONFIRMED** (traceable to a named flow node) or **NEEDS-CLIENT / NEEDS-LEGACY-DB**
(the flow cannot answer it).

**Bisnago = the SECOND SITE of the bispharma factory group.** Legacy **enterprise
119** (related-but-separate from bispharma ent 4). The PubSub topic name
(`bispharma_bisnago_publisher`) is the only in-flow trace of the group link.

> **The single most important finding:** Bisnago's legacy integration is the
> **pre-SparkPlug numeric-counter model**, NOT the packml_topic-string SparkPlug-B
> model that CPACK/bispharma/the new stack use. The flow emits numeric counter ids
> (670..683) to a GCP PubSub topic; the counter-id → equipment mapping lives in the
> **legacy ent-119 cloud DB**, not in the flow. This is the deepest structural
> difference from every other tenant onboarded so far, and it is why the descriptor
> is necessarily partial.

---

## Axis 1 — Telemetry (PLC → OEE)

### 1.1 The S7 endpoints — 19 configured, **7 active** (CONFIRMED)

All 19 endpoints are Siemens S7 over `iso-on-tcp`, port **102**, **rack 0 / slot 2**,
**cycletime 30000 ms** (30 s poll), timeout 1500 ms. But only **7** are wired to an
`s7 in` reader AND appear in the watchdog `ping` host list — the other **12 are
dormant** (configured, never read).

**The dormant/active split is a subnet split:** every active PLC is on
`192.168.7.x`; every dormant one is on `192.168.5.x` (plus a couple 7.x). This is
the classic signature of a **line migration** — bisnago moved its live lines to a
new PLC subnet and left the old endpoint configs in the flow. Treat the 12 dormant
lines as **decommissioned unless the client says otherwise** (NEEDS-CLIENT to
confirm none are merely paused).

| Line (active) | PLC IP | rack/slot | cycle | s7-in reader | counter fn |
|---|---|---|---|---|---|
| **L71** | 192.168.7.5  | 0/2 | 30 s | `PLC L71` | `counters L71` / `counters L71 NEW` |
| **L72** | 192.168.7.9  | 0/2 | 30 s | `PLC L72` | `counters L72` |
| **L73** | 192.168.7.13 | 0/2 | 30 s | `PLC L73` | `counters L73` / `counters L73 NEW` |
| **L56** | 192.168.7.17 | 0/2 | 30 s | `PLC L56` | `counters L56` |
| **L57** | 192.168.7.21 | 0/2 | 30 s | `PLC L57` | `counters L57` |
| **L58** | 192.168.7.25 | 0/2 | 30 s | `PLC L58` | `counters L58` |
| **L60** | 192.168.7.29 | 0/2 | 30 s | `PLC L60` | `counters L60` |

**Dormant (12, NOT read — likely decommissioned):** L12 `192.168.5.6`, L16
`192.168.5.7`, L06 `192.168.5.8`, L13 `192.168.5.9`, L14 `192.168.5.10`, L03
`192.168.5.11`, L18 `192.168.5.12`, L07 `192.168.5.13`, L04 `192.168.5.14`, L05
`192.168.5.15`, PLC-20 `192.168.5.16`, PLC-19 `192.168.5.17`.

> Two endpoint quirks (CONFIRMED, low-impact): `Config PLC L73` uses `connmode:
> rack-slot` while all others use `connmode: tsap` (localTSAP 01/00, remoteTSAP
> 02/00). `Config PLC 71`'s vartable mislabels its `DB1,DINT4` as name **`DW40`**
> (typo) — harmless because `counters L71` reads DW8+DW0, not DW4.

### 1.2 The read set — S7 addresses & tags (CONFIRMED)

Every active PLC reads the same **DB1** layout via `s7 in` `mode: all` (reads the
whole vartable each poll). All count tags are **`DINT`** (32-bit signed) at DB1:

```
DB1,DINT0  → DW0     DB1,DINT12 → DW12
DB1,B990   → B990    DB1,DINT16 → DW16   (read, UNUSED in transform)
DB1,DINT4  → DW4     DB1,DINT20 → DW20   (read, UNUSED; s7-in display var)
DB1,DINT8  → DW8     DB1,DINT24 → DW24   (L56/57/58/60 only; UNUSED)
                     DB1,DINT28 → DW28   (dormant L18 only)
```

Only **2 of these DINTs per line** are actually consumed by the counter transform
(see 1.4). `B990` (a single byte at offset 990), `DW16`, `DW20`, `DW24` are read
off the PLC but **never used** by any active function — candidates for an
additional count / a state byte the legacy flow ignores. **NEEDS-CLIENT**: what do
B990/DW16/DW20 mean? (Possible state or a 2nd/3rd count not yet wired.)

### 1.3 Topology / naming — **no packml_topic strings exist** (CONFIRMED-absent)

The 25 function nodes build **no** enterprise/site/area/line/machine topic string.
`grep` over the entire flow: `packml` 0, `sparkplug` 0. Routing is purely by the
**numeric counter id** embedded in the payload. Therefore:

- The `Bisnago/...` topic tree, site short-code, area names, and machine names are
  **NEEDS-LEGACY-DB** (pull from ent-119 `enterprises/sites/areas/equipments`,
  SELECT-only) — they are NOT in the flow.
- What the flow DOES give: 7 line **labels** (L71/L72/L73/L56/L57/L58/L60) and the
  numeric counter ids per line. That's the entire recoverable topology.

### 1.4 Counter semantics — **ABSOLUTE TOTALIZER + derived delta** (CONFIRMED)

Each `counters Lxx` function reads 2 DINTs and, per counter, does:

```js
var counter = msg.payload['DWx']            // absolute totalizer value (DINT)
var old = context.get('oldCounter_N')
increment = (old !== undefined && old <= counter) ? counter - old : 0   // delta, clamp on reset
context.set('oldCounter_N', counter)
// emits BOTH: {id:N},{value:counter},{increment},{timestamp},{ts_utc}
```

- **`value` = the raw ABSOLUTE TOTALIZER** (ever-increasing DINT; wraps/resets → the
  `<=` guard zeroes the delta). This is exactly the shape the new-stack Calc expects
  (plc-sim sims absolute totalizers; feedback_bug #15). **Directly compatible.**
- `increment` = per-poll delta the legacy cloud consumed. The new stack recomputes
  its own delta from `value`, so we forward **`value`** as the canonical count.
- Timestamps are stamped **UTC-3** (`ts.setHours(getHours()-3)`) — Brazil local;
  `ts_utc` carries the UTC copy. (Naming/TZ note for the ingest mapping.)
- The `function 1` test injector hard-codes sample values (`DW0:376265, DW8:413325,
  DW12:412171, DW16:406578`) — large monotonic numbers, corroborating **totalizer**.

**Counter-id map (CONFIRMED — which DINT feeds which legacy id):**

| Line | DINT→id (a) | DINT→id (b) |
|---|---|---|
| L71 | DW8 → **670** | DW0 → **671** |
| L72 | DW12 → **672** | DW0 → **673** |
| L73 | DW4 → **674** | DW0 → **675** |
| L56 | DW0 → **676** | DW4 → **677** |
| L57 | DW0 → **678** | DW4 → **679** |
| L58 | DW0 → **680** | DW4 → **681** |
| L60 | DW0 → **682** | DW4 → **683** |

14 counters, ids **670–683**, exactly **2 per line**. **NEEDS-LEGACY-DB**: whether
the 2 ids per line are (a) two machines on one line, or (b) two metrics
(processed + consumed/defective) of one machine. In the legacy model each distinct
id = a distinct `equipment_values.id_equipment` registration in ent 119 — resolve
by joining ids 670–683 to the ent-119 equipment table. Which DINT is "good count"
vs the other is likewise **NEEDS-LEGACY-DB** (the flow labels neither).

> Note the DW0-slot inconsistency: L71/L72/L73 put DW0 on the **odd** id; L56/57/58/60
> put DW0 on the **even** id. The count-channel order is NOT positional — another
> reason the id meaning must be read from the legacy DB, not inferred.

### 1.5 Speed — **NONE** (CONFIRMED). 1.6 State — **NONE** (CONFIRMED)

`grep` over the flow: `MachSpeed` 0, `speed` 0, `StateCurrent` 0, `state` (as a
signal) 0. There is **no speed sensor and no machine-state signal** on any bisnago
PLC. Consequences for OEE:

- **Performance** must be computed **counters-only** against a **rated/ideal speed
  per line** → `equipments.production_speed`. **NEEDS-CLIENT** (units per minute,
  per line; confirm unit matches the count unit).
- **Availability** must be **inferred from counter activity** — every machine is
  **`status_type != 4`** (no event-driven state). This gates EventMint scope: bisnago
  machines must **NOT** get per-sample OPEN events minted, or running_time overflows
  (feedback_bug_eventmint↔deriver scope mismatch). Flag on the tenant-prep.
- **Quality** needs a defective/consumed source — only available IF the 2nd id per
  line turns out to be a consumed/defective count (1.4, NEEDS-LEGACY-DB). Otherwise
  Quality is not computable from the current tag set.

---

## Axis 2 — Customizations / back4 integration

**CONFIRMED: ZERO external customization calls in the bisnago flow.**

Exhaustive sweep of the flow: `http` 0, `msg.url` 0, `fetch` 0, `request` 0,
`back4` 0, `api4` 0, `apijobreport` 0, `jobintegration` 0, `/events` 0, `/jobs` 0.
There are **no `http request` nodes** and **no function node makes an HTTP call**.

The only non-telemetry nodes are an internal **watchdog**, not a customization:

| Node | Type | Purpose |
|---|---|---|
| `ping` (7 hosts) → `switch T>0.5s` | ping/switch | liveness probe of the 7 active PLCs |
| `pubsub cutucador` inject → `trigger` (30 s) → `exec` | inject/trigger/exec | if PubSub stalls, `exec: pm2 restart 0` restarts the flow |
| `pack-queue` | pack-queue | local SQLite store-and-forward buffer (`/home/pi/.node-red/queue.sqlite`, 300 s) before PubSub |
| `pack-pubsub` | GCP PubSub out | the ONLY external egress → `bispharma_bisnago_publisher` |

**`exec: pm2 restart 0`** is a **local process-manager restart** (self-heal on
PubSub disconnect), NOT a back4 call.

**Shim implication:** the ADR-0031 anti-corruption shim framework in
`services/refdata-api` currently covers **NEOPAC** (`/ext/neopac/sap-report*`),
**Montebello** (`/ext/montebello/*`), **Incoplast** (`/ext/incoplast/events|jobs`),
and **Family-A** (`/integration/job_report`, `/integration/job_data_integration`,
`/integration/get-shift-validation`). Bisnago (and bispharma) have **0** shim rows
today — and **bisnago needs none from this flow**: it makes no back4 calls. **If**
the bispharma group runs custom back4 jobs, they live in a *separate* bispharma/
CS-Admin low-code flow, not in this telemetry flow. **No new shim required for
bisnago onboarding.** (Verify separately whether a bispharma-group job flow exists.)

---

## How bisnago DIFFERS from bispharma and CPACK

| Dimension | **Bisnago** (this flow) | bispharma (scaffold) | CPACK |
|---|---|---|---|
| Legacy enterprise | **119** (2nd site of bispharma group) | 4 (shell, ~65 users, no data) | prod 1 / staging 3 |
| Integration model | **legacy numeric-counter → PubSub** | greenfield (TBD) | **SparkPlug-B topic strings** |
| Builds packml_topic? | **NO — numeric ids 670–683** | N/A (greenfield) | **YES** (`CPACK/SC/...`) |
| PLC protocol | **S7, 19 endpoints / 7 active** | unknown (intake blocked) | SparkPlug B native |
| S7 endpoint count | **19 cfg / 7 live** (≠ bispharma's 16+16 claim) | N/A | N/A |
| Count semantics | **absolute totalizer DINT + derived delta** | unknown | absolute totalizer |
| Speed sensor | **NONE (counters-only)** | unknown | present (`/Status/MachSpeed`) |
| State signal | **NONE (status_type≠4, inferred)** | unknown | present (`/Status/StateCurrent`) |
| Count index | **legacy counter id 670–683** (not a captured `/idx/Unit`) | captured live (P2) | captured `<idx>` (#601) |
| back4 customizations | **ZERO** (no shim needed) | unknown | none in tee (telemetry only) |
| Edge host | **Raspberry Pi** (`/home/pi/.node-red`, `pm2`) | TBD (container likely) | tee/container |
| Timezone stamp | **UTC-3 in-flow** | N/A | (stack-side) |

**Assume nothing carries over** (per hard rule): bisnago's PLC set, subnets, tag
layout, counter-id scheme, and the *absence* of speed/state are all independent
ground truth extracted here — none copied from bispharma or CPACK.

---

## CONFIRMED-from-flow vs NEEDS-CLIENT / NEEDS-LEGACY-DB

**CONFIRMED (from a named flow node):**
- 7 active lines + their PLC IP/rack/slot/cycle; 12 dormant endpoints (subnet split).
- S7 DB1 DINT read set; the 2 DINTs consumed per line; B990/DW16/DW20/DW24 read-but-unused.
- Counter-id map 670–683 (which DINT → which id, per line).
- Absolute-totalizer `value` + clamped `increment` delta; 30 s poll; UTC-3 stamp.
- Counters-only: NO speed, NO state signal anywhere.
- ZERO back4/HTTP customization calls; PubSub `bispharma_bisnago_publisher` sole egress.
- Legacy Raspberry-Pi edge (`pm2`, SQLite store-and-forward), self-heal watchdog.

**NEEDS-LEGACY-DB (pull from ent-119, SELECT-only):**
- Enterprise/site/area/line/**machine** names → the `canonical.prefix` + topic tree.
- id_equipment surrogates for each of the 14 counter registrations.
- Meaning of the 2 ids per line (2 machines vs processed+consumed/defective) and
  which DINT is the "good" count.
- Confirm the 12 `192.168.5.x` lines are decommissioned (not merely paused).

**NEEDS-CLIENT:**
- Rated/ideal speed per line (parts/min) for the counters-only Performance path.
- Meaning of B990 / DW16 / DW20 (state byte? extra count?).
- Edge decision: rebuilt tee vs client-edge container; the staging ingest front-door
  + egress IP for the SG allowlist.
- Whether a *separate* bispharma-group back4 job flow exists (would need its own shim).

---

## onboard-gen status

`onboard-gen` was **NOT run**: (a) it is not present on `staging`
(lives on `feat/task13-adr0045-p1-client-descriptor-generator`), and (b) the
descriptor is intentionally incomplete — `enterprise_id: 0`, placeholder
`BISNAGO/TODO_SITE` prefix and topics, sentinel ids — so it would (correctly) fail
`Validate()` (`enterprise_id` guard, `topic must start with prefix`,
`id_equipment > 0`). It becomes runnable once the NEEDS-LEGACY-DB tree is pulled and
transcribed into `bisnago.descriptor.yaml`.
