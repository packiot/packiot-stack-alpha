# Bispharma — client onboarding INTAKE (data-gathering checklist)

**Status: BLOCKED on client facts.** Bispharma is a *greenfield* tenant — legacy
enterprise 4, a shell with ~65 Firebase users but **ZERO topology and ZERO PLC
data**. There is nothing to reverse-engineer (contrast CPACK/Incoplast, whose
topics we recovered from live tees / prod tables). Every field below must be
**obtained from Bispharma or their systems integrator** before anything on the
ADR-0045 pipeline can run.

This is the fillable intake. Each section maps 1:1 to a block in
[`bispharma.descriptor.yaml`](bispharma.descriptor.yaml). When a fact arrives,
fill it here first (human-readable), then transcribe into the descriptor and run
`onboard-gen`.

> **The one rule that governs this whole doc (ADR-0045 §2.4b):** a machine's
> count index — the `<IDX>` in `…/Admin/ProdProcessedCount/<IDX>/Unit` — is an
> **arbitrary PLC channel number that is NOT derivable from anything** (CPACK
> #601: `BREYER1` reports on channel 26 while its id_equipment is 340). It can
> only be **captured from a live tee**, machine by machine. So the intake gets us
> to a *generated, observe-mode* config; the indices are then confirmed by the P2
> capture step. No tenant cuts over on inferred indices.

---

## Legend

- **[REQUIRED]** — cannot generate a working descriptor without it.
- **[REQUIRED-CAPTURE]** — a value that is *live-captured* on staging (P2), not
  told to us. We still need to know it *exists*; the number is observed.
- **[FALLBACK]** — only needed if a sensor is absent (drives the counters-only path).
- **[COSMETIC]** — naming/labels; affects display + topic strings, not routing math.

---

## 1. PLC / transport protocol  **[REQUIRED]**

How does data leave Bispharma's floor today? This decides the *edge* shape (§2)
and whether we ingest SparkPlug directly or transform raw tags stack-side.

- [ ] **Protocol per machine / line.** One of:
  - `SparkPlug B (MQTT)` — already speaks our native model → thinnest path.
  - `Modbus TCP` — register map required (addr → meaning, per machine).
  - `Siemens S7` (S7-300/400/1200/1500) — rack/slot + DB/offset map required.
  - `OPC-UA` — endpoint URL + node-id map.
  - `raw MQTT` (non-SparkPlug JSON) — topic + payload shape samples.
  - other / mixed — describe per machine.
- [ ] **If Modbus/S7/OPC-UA:** the address/register/node map per metric per
      machine (counters, speed, state). We need the *raw* addresses; the mapping
      to canonical leaves happens stack-side (ADR-0045 §2.3 Option B).
- [ ] **Sample payloads.** 2–3 real messages per machine (redacted of secrets).
      These are gold — they reveal the *actual* leaf names, casing, and the
      count `<IDX>` shape before we ever tee.
- [ ] **Polling vs report-by-exception**, and the update cadence (Hz / seconds).

## 2. The edge — do they have Node-RED, or do we deploy our container?  **[REQUIRED]**

- [ ] **Does Bispharma already run Node-RED** (or any edge broker/gateway) on-site?
  - **Yes** → they install a **tee node** (a dumb raw-forwarder; ADR-0042 §2.3)
    after their PLC-read node. We generate the tee snippet from the descriptor.
  - **No** → **we deploy the client-edge container** (a parallel agent is building
    it) on-site or in their DMZ; it reads the PLC and forwards raw tags to our
    ingest front-door. This is the greenfield-default assumption for Bispharma.
- [ ] **Edge host reachability.** Can the edge make **outbound HTTPS** to our
      staging ingest front-door? (We do NOT need inbound to their floor.) Note any
      proxy / egress firewall — we allowlist their egress IP on the SG.
- [ ] **Edge egress public IP(s)** — for the staging SG allowlist rule.
- [ ] **On-site compute** for our container if we deploy it: OS, arch (x86_64 /
      arm64), CPU/RAM, Docker present?, outbound-only network.

## 3. Enterprise / site / area / line / machine TREE  **[REQUIRED]**

The physical hierarchy. Drives the `equipments` rows + the topic strings. Fill
the tree; every leaf machine becomes a `tp_equipment=1` row, every line a
`tp_equipment=3` row (sectors `tp=2` if used).

```
enterprise: Bispharma
└── site:  <TODO site name>            (e.g. a plant/city)
    └── area: <TODO area/sector name>  (e.g. "BLISTER", "ENVASE")
        ├── line: <TODO line name>     tp=3
        │   ├── machine: <TODO>        tp=1
        │   └── machine: <TODO>        tp=1
        └── line: <TODO line name>     tp=3
            └── machine: <TODO>        tp=1
```

- [ ] Full tree, all names. **How many lines? How many machines total?**
- [ ] Per line: which machine is the **lead machine** (generates the line's
      downtime events)? Default = first machine in the line.
- [ ] Per machine: **`status_type`** — does the machine emit a real state signal
      (`status_type=4`, event-driven) or do we infer state from speed/counters?
      (This gates EventMint scope — a status_type≠4 machine must NOT get per-sample
      OPEN events minted, or running_time overflows; feedback_bug_eventmint.)
- [ ] Per machine: `id_unit` (for a standalone machine, `id_unit = id_equipment`).

## 4. Per-machine METRIC AVAILABILITY  **[REQUIRED]** — the OEE-critical block

For **each machine**, which of the three OEE input signals actually exist on the
PLC? OEE = Availability × Performance × Quality; each needs a source.

| Metric | Question | If present | If absent |
|--------|----------|-----------|-----------|
| **Production count** | Is there a good/processed-parts counter? | Is it an **absolute totalizer** (ever-increasing, wraps) or **incremental** (delta per message)? | no OEE possible — must have a count |
| **Consumed / infeed count** | Raw-material / infeed counter? | drives Quality (defective = consumed − processed) | Quality can't be computed; flag |
| **Defective / reject count** | Explicit reject counter? | direct Quality | derive from consumed−processed if both exist |
| **MachSpeed** | Live speed sensor / tach? | drives Performance directly | **counters-only path** → need rated speed (§6) |
| **StateCurrent** | Real machine-state signal? | drives Availability directly (`status_type=4`) | infer state from count/speed activity |

- [ ] Fill the above table **per machine**. This is the single most important
      artifact — it decides which metric-template leaves apply and whether each
      machine is on the **counters-only** path.
- [ ] **Totalizer vs incremental** matters a lot: our Calc expects **absolute
      totalizers** (the plc-sim faithfully sims absolute totalizers; #15). If a
      machine sends incremental deltas, flag it — the transform differs and a
      sanity-clamp is needed against counter resets/rollover.

## 5. Count index per machine  **[REQUIRED-CAPTURE]**

- [ ] Confirm each machine **has** a `…/Admin/ProdProcessedCount/<IDX>/Unit`-style
      indexed count leaf (or the protocol equivalent). We do **not** ask the client
      for the `<IDX>` number — it is **captured live** on staging via P2
      (`onboard-capture`). We only need to know the leaf *shape* exists so the
      member metric-template applies.
- [ ] If the count is a **bare** leaf (no `<IDX>`), note it — that machine uses
      `count_index.mode = equipment_id` (the default fallback), no capture needed.

## 6. Ideal / rated speed per machine  **[FALLBACK — counters-only]**

- [ ] For **every machine with NO MachSpeed sensor** (§4), we need the **rated /
      ideal speed** (units per minute) to compute Performance from counters alone.
      This becomes `equipments.production_speed`.
- [ ] Units: parts/min? Confirm the unit matches the count unit (parts vs boxes vs
      meters). A unit mismatch silently corrupts Performance %.
- [ ] If speed varies by product/SKU, note the nominal/most-common value for
      first validation; per-SKU speed is a later refinement.

## 7. Topic naming — accents, hyphens, casing  **[REQUIRED / COSMETIC-ish]**

Topic strings are load-bearing for routing (they key `packml_register`) AND they
have bitten us before (Incoplast topic-shape mismatch; CPACK `C-PACK/`→`CPACK/`).

- [ ] **Canonical prefix** — the head every topic starts with, e.g. `BISPHARMA/<SITE>`.
      TBD until §3 names land.
- [ ] **Accents / special chars.** Do machine names carry `ç`, `ã`, `-`, spaces?
      (Portuguese plant names often do.) We need the EXACT bytes the PLC emits —
      a prefix fixup / alias absorbs any raw→canonical difference **stack-side**.
- [ ] **Casing.** Upper/lower/mixed as the PLC sends it. Discovery lower-cases the
      tenant segment; the rest is preserved.
- [ ] **Hyphens vs slashes** in machine ids (CPACK has `PTH40-03`). Confirm the
      real separators so the topic parse is correct.
- [ ] Any known raw→canonical quirks (a wrong leaf name like CPACK's
      `CurMachSpeed`→`MachSpeed`, or a `C-PACK/`-style head) → these become
      `metric_aliases` / `prefix_fixups` in the descriptor `mapping:` block.

## 8. Firebase users (already partially known)

- [ ] The ~65 Firebase users on legacy ent 4 are **known to exist**. We pull their
      `email` + `id_user_firebase` **SELECT-only from legacy prod** and seed them
      into staging `users` so their logins resolve once data flows (see
      [`bispharma-staging-tenant-prep.md`](bispharma-staging-tenant-prep.md) §2).
      Real UIDs/emails are **never committed** — the seed is generated at apply
      time, kept out of git.
- [ ] Confirm which of the 65 should be active for the staging validation (all, or
      a pilot subset?).

---

## What we can proceed with TODAY (nothing that needs the client)

- Scaffold + reserve the staging enterprise/site/area shell (names TBD → rename later).
- Prepare the users-seed procedure (§8) — pull + generate, hold for apply.
- Stand up the client-edge container image (parallel agent) so it's ready to point
  at staging the moment §1/§2 facts + a tee endpoint exist.

**Everything else is gated on §1–§7.** The CRITICAL blocker is obtaining
Bispharma's actual PLC/edge facts. Until those land, the descriptor stays a
template full of TODOs and `onboard-gen` cannot produce a routable config.
