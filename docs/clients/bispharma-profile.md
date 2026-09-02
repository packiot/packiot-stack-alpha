# Bispharma — extracted client profile (from the legacy Node-RED flow)

**Source of truth:** `bispharma.json` — the client's legacy factory Node-RED flow
(71 nodes: 16 `s7 endpoint`, 16 `s7 in`, 19 `function`, 1 `packiot-google-cloud-pubsub out`,
+ debug/inject/exec/catch helpers). Every fact below cites the flow node it came from.
This document is the ground-truth extraction that fills
[`bispharma.descriptor.yaml`](bispharma.descriptor.yaml); the descriptor generates the
four onboarding artifacts under [`gen/`](gen/).

> **Headline:** the intake doc ([`bispharma-intake.md`](bispharma-intake.md)) assumed
> Bispharma was greenfield with *zero PLC facts*. **That is now obsolete** — the legacy
> flow resolves intake §1 (protocol), §2 (edge), §4 (metric availability) and §5 (count
> indices) outright. What genuinely remains client-gated is narrow: **names, staging ids,
> and rated speeds.**

---

## TL;DR — the two migration axes

| Axis | Finding |
|------|---------|
| **1. Telemetry (PLC → OEE)** | 16 Siemens S7 PLCs → Node-RED (`counters LXX` fns) → GCP PubSub `projects/packiot/topics/bispharma`. **Absolute totalizers** (S7 DINTs), deltas computed edge-side. **Counters-only** (no speed, no state, no PackML params). Routing key = **numeric count-index** (124..685), **no topic strings anywhere**. |
| **2. Customizations (back4 integration)** | **EMPTY.** Zero `http request` nodes, zero back4-api calls, zero `apijobreport`/`jobintegration`/`events`/`jobs` endpoints. The only non-telemetry node is one `exec` running `pm2 restart 0` (internal watchdog). Bispharma needs **no ADR-0031 back4 shim.** |

**Recommended edge approach:** keep their Node-RED + add a **transforming tee** (they run
Node-RED on a Raspberry Pi already). NOT a dumb forwarder — see §7.

---

## 1. PLC connectivity map — 16 Siemens S7 endpoints

All 16 `s7 endpoint` nodes: **iso-on-tcp, port 102, rack 0, slot 2** (S7-300/400 family),
**cycletime 30000 ms (30 s)**, timeout 1500 ms, on subnet **192.168.5.0/24**. Uniform.

| Line | Endpoint node name | PLC IP | vartable |
|------|--------------------|--------|----------|
| L01 | Config PLC 01 | 192.168.5.3 | 6×DINT + B990 |
| L03 | Config PLC L03 | 192.168.5.11 | 6×DINT + B990 |
| L04 | Config PLC L04 | 192.168.5.14 | 6×DINT + B990 |
| L05 | PLC L05 | 192.168.5.15 | 6×DINT + B990 |
| L06 | Config PLC L06 | 192.168.5.8 | 6×DINT + B990 |
| L07 | Config PLC L07 | 192.168.5.13 | 6×DINT + B990 |
| L09 | Config PLC L09 | 192.168.5.4 | 6×DINT + B990 |
| L11 | Config PLC L11 | 192.168.5.5 | 6×DINT + B990 |
| L12 | Config PLC L12 | 192.168.5.6 | 6×DINT + B990 |
| L13 | Config PLC L13 | 192.168.5.9 | 6×DINT + B990 |
| L14 | Config PLC L14 | 192.168.5.10 | 6×DINT + B990 |
| L16 | Config PLC L16 | 192.168.5.7 | 6×DINT + B990 |
| L18 | Config PLC L18 | 192.168.5.12 | **8×DINT** + B990 |
| L19 | Config PLC 19 | 192.168.5.17 | 6×DINT + B990 |
| L20 | Config PLC 20 | 192.168.5.16 | 6×DINT + B990 |
| L90 | PLC L90 | 192.168.5.82 | **8×DINT** (named DW0..DW7, no B990) |

These are **16 distinct PLCs / production lines** (not one PLC with 16 connections).

---

## 2. Raw S7 tag inventory (the `s7 in` + vartable)

Each `s7 in` node reads its endpoint with **`mode: all`** (reads the whole vartable each
cycle) and feeds one `counters LXX` function. The standard vartable (all lines except
L18/L90):

| Address | var name | S7 type | role (derived, §3) |
|---------|----------|---------|--------------------|
| `DB1,DINT0`  | DW0  | DINT (32-bit signed) | infeed / first sensor |
| `DB1,DINT4`  | DW4  | DINT | 2nd sensor (only used inside the scrap difference) |
| `DB1,DINT8`  | DW8  | DINT | station sensor |
| `DB1,DINT12` | DW12 | DINT | station sensor |
| `DB1,DINT16` | DW16 | DINT | station sensor |
| `DB1,DINT20` | DW20 | DINT | last sensor / final output |
| `DB1,B990`   | B990 | BYTE | **read but NEVER referenced** in any function — a dead/unused tag (possibly an intended-but-abandoned status byte) |

- **L18** (`Config PLC L18`) reads **DB1,DINT0..DINT28** (8 DINTs) and remaps them (§3).
- **L90** (`PLC L90`) reads **DB1,DINT0..DINT28** (8 DINTs) but names them `DW0..DW7`; only
  DW0/DW1 are used.

**All production tags are DB1 DINTs.** No FLOAT/REAL, no BOOL, no string. → **counters-only.**

---

## 3. Transformation logic — the 16 `counters LXX` function nodes

Each `counters LXX` node does the identical thing (verified across all 16): read the
vartable DINTs, assign each to a globally-unique **count-index id**, compute a per-cycle
**increment** from a value cached in Node-RED `context`, and emit a JSON payload. Example
(`counters L09`, verbatim structure):

```js
counter127 = msg.payload['DW20']
counter126 = msg.payload['DW16']
counter125 = msg.payload['DW12']
counter124 = msg.payload['DW8']
counter129 = msg.payload['DW0'] - msg.payload['DW4']  // "last sensor is the only one for scrap"
counter128 = msg.payload['DW0']
// per counter:
var old = context.get('oldCounter124')
if (old) { vlIncrement124 = (old <= counter124) ? counter124 - old : 0 } else { vlIncrement124 = 0 }
context.set('oldCounter124', counter124)
// ... emits: { counters:[ { counterData:[ {id:124},{value:counter124},{timestamp},{increment:vlIncrement124},{ts_utc} ] }, ... ] }
```

### 3a. Counter semantics — **ABSOLUTE TOTALIZERS** (critical)

The S7 DINTs are **lifetime absolute totalizers**. Two independent proofs from the flow:

1. Each node caches `oldCounterN` in `context` and publishes `increment = current − old`.
   You only compute deltas edge-side if the source is a running total.
2. The **reset-guard** `if (old <= current) increment = current − old; else increment = 0`
   — the classic monotonic-totalizer rollover/reset handler. Meaningless for an already-
   incremental source.

Both `value` (absolute) **and** `increment` (per-30s delta) are published per count-index.

> **Divergence from CPACK:** CPACK is *also* totalizer-based, but CPACK sends the **raw
> absolute** count and the **cloud/Go** computes the delta. Bispharma computes the delta
> **edge-side** in Node-RED `context`. This is a **delta-ownership** difference: if the new
> stack's Calc computes its own delta from `value` (the stack's normal path, matching CPACK),
> we should ingest **`value`** and IGNORE the flow's `increment` (single-writer-of-delta
> rule; cf. the two-writer line double-count bug). If instead we ingest `increment`, note the
> flow zeroes it across a Node-RED restart (cold `context`) — a small, bounded under-count.
> **Recommendation:** ingest `value`, let the stack derive the delta + apply the increment
> sanity-clamp (cf. `feat/task13-increment-sanity-clamp-eq57`).

### 3b. Counter → count-index → DW map (standard line)

Per standard line the six count-indices map to DWs as (shown for L09, id base 124):

| count-index | DW source | positional role | canonical member (synthesized) |
|-------------|-----------|-----------------|-------------------------------|
| base+4 (128) | `DW0` | infeed / first sensor | `…/S1_INFEED` |
| base+0 (124) | `DW8`  | station | `…/S3` |
| base+1 (125) | `DW12` | station | `…/S4` |
| base+2 (126) | `DW16` | station | `…/S5` |
| base+3 (127) | `DW20` | last sensor / final output | `…/S6_OUTPUT` |
| base+5 (129) | `DW0 − DW4` | **scrap / reject** | `…/SCRAP` |

`DW4` is never emitted as its own count-index — it appears only inside the scrap difference.

> **Scrap channel caveat:** `SCRAP = DW0 − DW4` is a *derived difference of two totalizers*,
> not itself a monotonic totalizer (it can fall). The flow still runs the totalizer-delta
> reset-guard on it, which is semantically dubious. Its true role is **ProdDefectiveCount**,
> not ProdProcessedCount. Flagged in the descriptor + assign the right OEE role at cutover.

### 3c. Count-index inventory (all 16 lines) — CONFIRMED FROM FLOW

| Line | PLC IP | count-indices | # | notes |
|------|--------|---------------|---|-------|
| L01 | .3 | 164–169 | 6 | standard |
| L03 | .11 | 307–312 | 6 | standard |
| L04 | .14 | 314–319 | 6 | standard (extra debug wire `L4`) |
| L05 | .15 | 624–629 | 6 | standard |
| L06 | .8 | 257–262 | 6 | standard |
| L07 | .13 | 320–325 | 6 | standard |
| L09 | .4 | 124–129 | 6 | standard |
| L11 | .5 | 170–175 | 6 | standard |
| L12 | .6 | 176–181 | 6 | standard |
| L13 | .9 | 301–306 | 6 | standard |
| L14 | .10 | 332–337 | 6 | standard |
| L16 | .7 | 182–187 | 6 | standard |
| **L18** | .12 | 543–550 | 8 (5 used) | **named machines**, see below |
| L19 | .17 | 643–648 | 6 | standard (extra debug wire `MessageL19`) |
| L20 | .16 | 649–654 | 6 | standard |
| **L90** | .82 | 684–685 | 2 | infeed + output only |

Total = **94 emitted count-indices** (91 registered as members after excluding L18's 3
`livre` spares). These are the **legacy routing keys** — the single most valuable extracted
fact, because they are what the cloud already understands.

### 3d. L18 — the one line whose machines are NAMED (gold)

`counters L18` carries an active remap with Portuguese station labels (and a commented-out
"old" mapping we correctly ignore):

| count-index | DW | machine (flow comment) |
|-------------|----|------------------------|
| 543 | DW8  | **PRENSA** (press) — "I3 Prensa" |
| 544 | DW12 | **TORNO** (lathe) — "I4 Torno" |
| 546 | DW16 | **ACUMULADOR** (accumulator) — "I5 Acumulador" |
| 548 | DW20 | **IMPRESSAO** (printing) — "I6 Impressao" |
| 549 | DW0  | **TAMPADEIRA** (capper) — "I1 Tampadeira" |
| 545 / 547 / 550 | DW4 / DW24 / DW28 | **`livre`** (free/unwired spare) — NOT registered |

L18 **confirms the equipment model**: each count-index is a distinct **machine** on a line,
not merely a sensor. It's the Rosetta stone for what the other 15 lines' count-indices
*are* — but only L18's machines are named in the flow (the rest are `NEEDS-CLIENT`, §Gaps).

### 3e. Speed & state — **NEITHER EXISTS**

- **No MachSpeed / CurMachSpeed tag** anywhere. All tags are DINT counters. → **counters-only
  Performance**: needs **rated/ideal speed** per equipment (`equipments.production_speed`) —
  a client fact (§Gaps). Availability inferred from count activity (cf.
  `oeecloud-worker` counters-only AVAILABILITY fallback, #600/#607).
- **No StateCurrent / PackML-state derivation.** `status_type` will be **≠4** (no event-driven
  state) → must NOT get per-sample OPEN events minted (EventMint↔deriver scope bug).
- **No PackML Parameter tags** (no 30700/30701/30702/30750/30758). No lead-machine, no ideal-
  speed param, no sequence. Much simpler/older than CPACK's Parameter-carrying stream.

---

## 4. Publish path — GCP PubSub (legacy)

`counters LXX` → **`pack-queue`** (`type: pack-queue`, a SQLite store-and-forward buffer at
`/home/pi/.node-red/queue.sqlite`, flush **interval 300 s**) → **`packiot-google-cloud-pubsub
out`** (`name: pack-pubsub`) → topic **`projects/packiot/topics/bispharma`**, projectId
`packiot`, GCP creds node "key bispharma". A `catch`+`trigger`+`inject`+`exec (pm2 restart 0)`
cluster restarts the flow if PubSub disconnects.

**PubSub payload shape** (what the new stack must map *from*):

```json
{ "counters": [
  { "counterData": [ {"id":124}, {"value":<abs totalizer>}, {"timestamp":<BRT, now−3h>},
                     {"increment":<per-30s delta>}, {"ts_utc":<UTC now>} ] },
  … one per count-index …
] }
```

Note the odd shape: `counterData` is an **array of single-key objects**, not one object.
Timestamps: `timestamp` is **BRT (UTC−3, hardcoded `ts.setHours(getHours()−3)`)**, `ts_utc`
is UTC. **Edge host = Raspberry Pi** (`/home/pi`, `pm2`).

---

## 5. The structural mismatch vs the new stack (and how the descriptor bridges it)

The ADR-0045 descriptor / sparkplug-agent model is **topic-keyed**: equipment is identified
by a SparkPlug topic string (`CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/57/Unit`)
and the count-index is *embedded in the topic*. **Bispharma emits no topics** — only bare
count-index ids in JSON. So onboarding requires a bridge:

- **We SYNTHESIZE canonical topics** (`BISPHARMA/SP/LINHAS/L09/S6_OUTPUT`, …) to give the
  stack its topic-keyed structure. The prefix/site/area/station names are our invention
  (COSMETIC / `NEEDS-CLIENT`).
- **We PIN each member's `count_index`** to the flow's literal id (`confidence: confirmed`).
  The synthesized member leaf becomes `…/Admin/ProdProcessedCount/<count_index>/Unit`, so the
  **count-index — the real legacy routing key — is preserved** end-to-end.

> **Inversion vs CPACK:** for CPACK the count-index was an *arbitrary, non-derivable* channel
> (#601) that had to be **captured live** and stayed `inferred` until a P2 tee run. For
> **bispharma the flow states every index literally**, so all 91 members are `confirmed` and
> the descriptor **passes `onboard-gen --cutover`** on count-index grounds today.

---

## 6. Customization / back4-integration surface (2nd migration axis) — **EMPTY**

Exhaustive search of `bispharma.json` for the customization axis the automation team wires
per client (`apijobreport`, `jobintegration`, `apiincoplast events/jobs`, `apimontebello
events`, any `http request` / external API):

- **Node type census:** `catch, comment, debug, exec, function, google-cloud-credentials,
  inject, pack-queue, packiot-google-cloud-pubsub out, s7 endpoint, s7 in, status, tab,
  trigger`. **No `http request` node type exists in the flow.**
- **String search** for `http`, `back4`, `api4`, `.com/`, `apijob*`, `jobintegration`,
  `apiincoplast`, `apimontebello`, `axios`, `request` → **zero hits.**
- The only `exec` node runs **`pm2 restart 0`** — an internal Node-RED watchdog, not a
  business integration.

**Conclusion:** bispharma's flow is **pure telemetry**. It needs **no ADR-0031 back4
anti-corruption shim** (contrast NEOPAC/Montebello/Incoplast/Family-A, which have shims on
`feat/task54-ws-b-family-a-shims`). **Caveat to confirm with the client:** business
integrations (job/PO reporting) *may* live outside this flow (a separate Node-RED tab, or the
client uses the product UI directly). This flow file shows none — verify no second flow exists.

---

## 7. Recommended edge approach — their Node-RED + a **transforming** tee

Bispharma **already runs Node-RED** on-site (Raspberry Pi, `pm2`, the `pack-queue`/PubSub
stack). So the fast path is **keep their Node-RED + add a tee** (like CPACK) rather than
deploying our client-edge container (#624). **But** — unlike CPACK, whose PLC already speaks
SparkPlug topics so the tee is a *dumb forwarder* — bispharma's tee must **transform**:

1. Tee off the `counters LXX` output (a second wire, not a redirect).
2. Map each `counterData{ id, value }` → a SparkPlug metric
   `{ name: "<synthesized-topic>/Admin/ProdProcessedCount/<id>/Unit", value, type:"double" }`
   using the count-index → topic table (= the descriptor's `count_index.overrides`, inverted).
3. Wrap as `{ timestamp, gateway:"bispharma-edge", metrics:[…] }` and POST to the ingest
   front-door (the generated `bispharma-tee-node.json` is the POST scaffold; the count-index→
   metric mapping step must be added ahead of it).

**Alternative (schema extension):** teach the ingest-shim a native **count-index ingestion
mode** so bispharma posts its raw JSON and the *stack* does the count-index→equipment mapping
(via `packml_register` keyed on count-index). Cleaner long-term (no client-side transform,
tee stays dumb) but it's a stack change. **Recommend the transforming-tee for first
validation; consider the schema extension if more count-index-keyed clients appear.**

---

## 8. Generated artifacts (`onboard-gen`, draft/observe mode)

From the filled descriptor, `cmd/onboard-gen` emitted four artifacts into [`gen/`](gen/):

| Artifact | Content |
|----------|---------|
| `bispharma-profile.yaml` | tenant conversion profile — 91 count_index overrides + counters-only templates |
| `bispharma-register.sql` | 107 idempotent `packml_register` rows (16 lines + 91 members) |
| `bispharma-agent.yaml` | sparkplug-agent config — 139 `raw_tag_map` entries (48 line + 91 member) |
| `bispharma-tee-node.json` | Node-RED tee POST scaffold (needs the count-index→metric transform, §7) |

`onboard-gen` reports **"all count indices CONFIRMED — cutover-eligible"** and passes
`--cutover` on count-index grounds. (Cutover is still gated on the §Gaps facts below.)

---

## 9. CONFIRMED-from-flow vs STILL-NEEDS-CLIENT

### Confirmed from the flow (do not re-ask the client)
- Protocol: **Siemens S7-300/400**, rack 0 / slot 2 / port 102 / iso-on-tcp, 30 s cycle.
- **16 PLCs / lines** + their **IPs** (192.168.5.x) + DB1 DINT addresses.
- **Absolute totalizers**; edge computes `increment` with a reset-guard.
- **Counters-only** (no speed, no state, no PackML params).
- **All 94 count-indices** and their DW sources + scrap formula (`DW0−DW4`).
- **L18's 5 machine names** (Prensa/Torno/Acumulador/Impressao/Tampadeira).
- Edge = **on-site Node-RED** (Raspberry Pi) → tee path viable.
- **No back4/customization** surface in this flow.

### Still needs client / tenant-prep (the real remaining blockers)
| Item | Why | Type |
|------|-----|------|
| **Rated / ideal speed per equipment** | no speed tag → counters-only Performance impossible without it | **[REQUIRED]** client |
| **Equipment-tree grouping per standard line** | are the 6 count-indices 6 machines (like L18) or sensor-stations on 1 machine? Decides tp=1 vs a single-machine line. The flow can't say for the 15 non-L18 lines | **[REQUIRED]** client / legacy DB |
| **Machine names (15 lines)** | only L18 named in the flow; S1..S6 are placeholders | [COSMETIC] client |
| **Which count-index is the line's good-output counter** | drives ProdProcessedCount vs infeed/scrap role | **[REQUIRED]** client |
| **Site / area names + canonical prefix** | `BISPHARMA/SP/LINHAS` is synthesized | [COSMETIC] client |
| **enterprise_id + all id_equipment** | `4` + `40001+` are synthetic; assign from a free staging block | tenant-prep |
| **Staging ingest front-door URL + `BISPHARMA_INGEST_KEY`** | `tee.ingest_url` is a TODO | tenant-prep |
| **Confirm no 2nd (integration) flow exists** | this flow is telemetry-only; job/PO reporting may live elsewhere | client |

> **Fastest way to close the tree/speed gaps:** the count-indices 124..685 very likely resolve
> to real `id_equipment` rows (names, rated speeds, tp tree) in the **legacy cloud DB** —
> the flow already publishes live to `projects/packiot/topics/bispharma`. A SELECT-only query
> (`equipments`/`packml_register` joined on those count-indices) would recover most of the
> `NEEDS-CLIENT` items without waiting on the client. Recommended next step.

---

## 10. Provenance index (fact → flow node)

- PLC IP/rack/slot/cycle → the 16 `s7 endpoint` nodes (§1).
- DB1 DINT addresses + B990 → each endpoint's `vartable` (§2).
- count-index ↔ DW ↔ increment/totalizer logic → the 16 `counters LXX` `function` nodes (§3).
- L18 machine names → `counters L18` inline comments (§3d).
- publish path + payload shape → `pack-queue` + `packiot-google-cloud-pubsub out` (§4).
- no customizations → node-type census + string search over the whole file (§6).
