# Onboarding a Client — Worked Example

A real, end-to-end walkthrough of onboarding a new client, using **Bispharma** as the
case study. It complements the conceptual [Onboarding a Client](02-onboarding.md) page:
that one tells you *what the wizard does*; this one shows *how a real onboarding actually
goes* — including the part no wizard can do for you, and the mistakes that look right.

> Sensitive values (PLC IPs, egress addresses, keys) are omitted or shown as
> `<plc-ip>` / `10.x.x.x`. The method is the point, not the addresses.

## The client shape

**Bispharma** (the enterprise) has **two sites**: `SP` (site 1) and `Bisnago` (site 2) —
separate factories on separate subnets, onboarded as two sites under one enterprise. This
example onboards **SP**: 16 production lines, each an S7 PLC. A line is 6 stations
(`S1INFEED · S3 · S4 · S5 · S6OUTPUT · SCRAP`); the PLC exposes their counters as a
packed array of 32-bit `DINT` totalizers in `DB1`.

The enterprise/site/area **names** compose the topic prefix (see ADR-0045): SP →
`BISPHARMASTAGING/SP/LINHAS/...`. That falls out of the hierarchy — you never type it.

## The five steps, and who owns each

| # | Step (csadmin) | Owner | What actually happens |
|---|----------------|-------|-----------------------|
| 1 | **Review the plant** | CS engineer | Confirm the lines/machines. The descriptor is composed from the hierarchy. |
| 2 | **Connect the PLCs** | CS engineer | Enter each line's PLC **host**. (Only the host — see below.) |
| 3 | **Go live (dry run)** | CS engineer | Generate the config, push the reader to the box, check it comes up. |
| 4 | **Confirm counts are real** (Capture) | CS engineer | Watch live counts, bind each machine to the right channel. |
| 5 | **Flip it on** (Cutover) | CS engineer | Final readiness, switch the client onto the new config. |

The box itself is enrolled **before** step 1 (Box Ops / SSM hybrid activation) so the
wizard has somewhere to deploy to.

## The part the wizard can't do: the PLC tag map

Step 2 captures a PLC's **host** — not which register feeds which machine. That binding
(`register address → tag → machine → counter role`) is **semantics**, and here is the
rule that governs the whole job:

> **The wire gives you syntax, never semantics.** You can read that a 32-bit counter at
> `HR[0:1]` climbs ~1.2/s. You cannot read that it is *good units off the filler*. Only
> the original integrator's program ever bound the address to its meaning.

So you do **not** guess the map from live values. You harvest it from **provenance** — the
first-version **Node-RED flow** the factory already ran. That single `flows.json` contains,
per PLC: the S7 endpoint (rack/slot/TSAP), the variable list (`DB1,DINT0` …), and the
function node that turns each variable into a named counter. That is the ground truth.

### Worked mapping (SP line L01)

The legacy `s7 endpoint` for L01 (rack 0 / slot 2, reads `DB1`) plus its `counters`
function decode a six-`DINT` array:

| S7 address | Modbus mirror | Machine | Counter role |
|------------|---------------|---------|--------------|
| `DB1,DINT0`  | `HR[0:1]`   | **S1INFEED** | gross / infeed → `ProdConsumedCount` |
| `DB1,DINT4`  | `HR[2:3]`   | *(S2 — no equipment)* | scrap subtrahend only |
| `DB1,DINT8`  | `HR[4:5]`   | **S3** | intermediate station |
| `DB1,DINT12` | `HR[6:7]`   | S4 | intermediate |
| `DB1,DINT16` | `HR[8:9]`   | S5 | intermediate |
| `DB1,DINT20` | `HR[10:11]` | **S6OUTPUT** | net / good → `ProdProcessedCount` |
| `DINT0 − DINT4` | — | **SCRAP** | scrap → `ProdDefectiveCount` |

!!! danger "The mistake that looks right (S3 ≠ output)"
    Sampling the PLC live shows **two** counters moving: `HR[0:1]` and `HR[4:5]`. The
    tempting map is *infeed + output*. It is **wrong**: `HR[4:5]` is **S3**, an
    intermediate station. Two independent tells prove it — the unread gap at `HR[2:3]`
    is exactly `DINT4` (read only to compute scrap, never its own counter), and
    `HR[4:5]` counts **faster** than the infeed, which is impossible for a real output on
    a serial line (net can't out-run gross). Wiring S3 as output would manufacture a
    phantom Quality (`net > gross`). The flow spelled it out; the wire never would.

### Two more real-world wrinkles

- **Protocol reality vs. descriptor.** The descriptor called L01 `s7`, but the device
  also serves **Modbus TCP** as a clean `DB1` mirror (`DB byte offset B → holding
  register B/2`). Prefer whichever is proven reachable from the box; the semantics are
  identical because it's the same `DB1`.
- **`counters_only_oee`.** L01's PLC exposes **no** machine state/speed (the lone status
  byte is declared-but-unused). So there is no `StateCurrent`/`MachSpeed` — OEE is derived
  from **counts + the shift schedule**. Emit counts only; don't invent a state signal.

## How the counts reach the cloud: shared multi-tenant ingest

A client is **data, not infrastructure.** There is **one** shared cloud ingest for all
tenants — you do **not** stand up a per-client agent, front-door, DNS record, or SG rule.

```
box Node-RED / reader  ──(WAN, TLS + X-Ingest-Key)──▶  ingest.<env>  (one shared nginx front-door)
   reads DB1 → rawtag envelope                             │  routes by envelope group_id
   {endpoint, scan_ts, tags:[{metric,value,…}]}            ▼
                                          sparkplug-agent (shared, multi-tenant)
                                            one isolated pipeline per group_id:
                                            resolver + aliases + session + uplink
                                            (strict allowlist per tenant)
                                                           │  SparkPlug B → internal mosquitto
                                                           ▼
                                          edge-transformer decode → Calc → equipment_values (ent 5)
```

Onboarding writes the tenant's `raw_tag_map` (generated from the descriptor) into the
shared agent; a new client adds a pipeline keyed by its `group_id`, nothing more. See
[Edge & Data Ingestion](04-edge-and-ingestion.md) for the tier model.

!!! warning "Envelope shape is exact"
    The reader POSTs `{endpoint, scan_ts, tags:[{metric, value, q, ts, param}]}` to
    `/v1/tags` with an `X-Ingest-Key` header, where `metric` is the **suffix** the agent
    allow-lists. The older `{timestamp, gateway, metrics[]}` shape is the *ingest-shim*
    contract and will be silently dropped by the agent (`202` with 0 accepted). Don't
    copy the legacy tee node verbatim.

## Step 4 (Capture) — using the map as an answer key

At Capture you confirm each machine reads the right channel. The table above is the answer
key. The rule: if a channel is counting **faster than infeed**, it is *not* the output —
it's an intermediate station. Bind `S1INFEED → DINT0`, `S6OUTPUT → DINT20`, scrap to
`DINT0 − DINT4`; the middle stations by ascending offset.

## Rules to remember

1. **Harvest, don't infer.** The legacy flow binds address→meaning; live values never do.
2. **A duplicate/foreign counter reads as real.** Only provenance tells you which is which.
3. **Net ≤ gross is a physical law.** Any mapping that violates it is wrong, not surprising.
4. **A client is data.** If onboarding needs an engineer to hand-write infra, the
   onboarding isn't finished — generalize it into the shared, config-as-data path.
5. **Absolute totalizers aren't comparable across PLCs** (they reset on different dates) —
   compare **increments**, not values, when validating a channel is live.

## See also

- [Onboarding a Client](02-onboarding.md) — the conceptual wizard flow (ADR-0045)
- [CS-Admin Forms Reference](03-csadmin-forms.md) — field-by-field
- [Edge & Data Ingestion](04-edge-and-ingestion.md) — the three-tier edge model (ADR-0042)
