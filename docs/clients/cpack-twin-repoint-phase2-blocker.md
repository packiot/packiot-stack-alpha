# CPACK twin re-point (legacy :1881 → new-stack :1880) — Phase 2 BLOCKED at P0

**Date:** 2026-08-25 · **Outcome:** cutover NOT executed. Stopped at the P0 gate.
**Live changes made:** none (investigation only — cloud nginx, the :1880 reader, and
the legacy :1881 feed are all untouched; instant revert is trivially armed).

## TL;DR

The Phase-2 plan (re-point the CPACK staging twin's ingest from the legacy `:1881`
reader onto the new-stack `:1880` reader via a cloud-edge nginx flip) is **safe and
reversible at the cloud edge, and P1 is already satisfied** — but **P0 cannot be met**:
the running `:1880` reader has a **generator defect** that means only **L6/TEXA** is
actually polled. Cutting the twin over would **regress the other four L6 members**
(BREYER / POLYTYPE / RMH / PTH), which the legacy feed currently provides. Per the
plan's own guardrail ("do not cut over to a regressing L6"), the cutover was not
performed.

## Root cause of the P0 block — duplicate Node-RED node ids

The generated Node-RED reader flow (`edge-cpack-nodered`, running flow at container
`/data/flows.json`, **not** the stale seed `/home/packiot/cpack-edge/cpack/cpack-reader-flow.json`)
contains **8 `modbus-read` nodes for L6 but only TWO unique node ids**:

| # | node id (as generated) | adr | member/metric |
|---|------------------------|-----|---------------|
| 1 | `cpack_mb_0_read_0` | 60  | L6/BREYER ProdConsumedCount/91 |
| 2 | `cpack_mb_0_read_0` | 10  | L6/POLYTYPE ProdConsumedCount/93 |
| 3 | `cpack_mb_0_read_0` | 100 | L6/PTH ProdConsumedCount/95 (InputRegister) |
| 4 | `cpack_mb_0_read_1` | 50  | L6/PTH ProdProcessedCount/95 |
| 5 | `cpack_mb_0_read_0` | 50  | L6/RMH ProdConsumedCount/94 |
| 6 | `cpack_mb_0_read_1` | 0   | L6/RMH ProdProcessedCount/94 |
| 7 | `cpack_mb_0_read_0` | 0   | L6/TEXA ProdConsumedCount/92 |
| 8 | `cpack_mb_0_read_1` | 0   | L6/TEXA ProdProcessedCount/92 |

Node-RED requires globally-unique node ids; with duplicates it instantiates **one node
per id** (last-definition-wins). Both surviving ids resolve to `adr=0` → **only L6/TEXA
is polled**. The other four members' reads are dead.

**Proof (live):** `docker logs edge-cpack-nodered` over 2000+ lines emits **only**
`/L6/TEXA/…` (400 occurrences); zero BREYER/POLYTYPE/RMH/PTH; **no modbus errors**
(rules out a read failure — it is the dup-id, not the PLC). The nodes self-poll at
`rate=15s`, so every live member would appear within seconds if it were instantiated.

The generator apparently cycles the tag-index suffix `_read_{0,1}` instead of assigning
`_read_{0..7}`. **This is the generator bug the follow-on agent must fix.**

## What a prior session already did (Aug 19, uncodified)

The running `/data/flows.json` (33.6 KB, mtime Aug 19) has diverged from the repo/seed
(27.9 KB, Aug 6) — a prior session edited the live flow via the Node-RED editor but
**never persisted to the seed file or the repo** (durability gap). Those edits:

- All 8 L6 `modbus-read` nodes: `quantity` **1 → 2** (16-bit → 32-bit pair). ✅
- `normalize` function Modbus branch now does 32-bit **low-word-first** reassembly:
  `v = (p.length>=2) ? (p[1]*65536 + p[0]) : Number(p[0])`. ✅ matches
  `cpack.plc.yaml` (`type:int32, word_swap:true`).
- Envelope converted seed→Tier-1 rawtag: `{endpoint, scan_ts, tags:[{metric,value,ts}]}`,
  `metric = name.replace("CPACK/SC","")`, plus `X-Ingest-Key: env CPACK_INGEST_KEY`.
- A `__DBG__` `node.warn` tap logging the first 3 `*Count` tags per message.

These are **correct as far as they go** — L6/TEXA now emits full 32-bit
(`266,042,097 → 266,047,625`, monotonic, matches the oracle **266,042,525**). But the
qty=2/combine fix is moot for the four dead members: they never poll.

## Evidence that P0 is genuinely required (L6 counts are 32-bit)

Oracle `packiot40` (prod ids) vs F3 twin `packiot_analytics` (legacy-fed, stg ids) —
`gross_production_val` totalizers agree to the digit and are all ~**2.9×10⁸** (≫ 65535):

| member (prod→stg) | oracle gross | F3 twin gross |
|---|---|---|
| L6/BREYER 91→68 | 291,789,977 | 291,788,640 |
| L6/TEXA   92→69 | 266,042,525 | 266,042,096 |
| L6/POLYTYPE 93→70 | 283,532,648 | 283,531,776 |
| L6/RMH    94→71 | 104,162,623 (gross) / 266,042,525 (net) | 104,162,456 / 266,042,096 |
| L6 line   90→50 | gross=BREYER(infeed), net=TEXA(outfeed) | same |

So the **legacy `:1881` feed reads L6 correctly (32-bit)** and the twin currently
**matches the oracle**. Cutting to a qty=1 (16-bit) `:1880` reader would wrap these to
`val mod 65536` (huge negative deltas → OEE glitch). The prior qty=2 fix addresses this
in principle — but only for TEXA, until the dup-id defect is fixed. L6 line = BREYER
(infeed) / TEXA (outfeed) confirms PR #905.

## What IS ready (unblocks the cutover once P0 is fixed)

- **P1 (agent map) — SATISFIED.** The cloud agent (`sparkplug-agent-cpack`,
  `172.18.0.38`) uses the **static** map `docs/clients/cpack-agent.yaml` (deployed at
  `origin/staging` `a7a0a5a`, incl. #904 L3-member map + #905 line-meter). It already
  covers all L3/L4/L5 members + **L8 members (idx 219–222)** + **L10 members (idx
  564–567)**. Cloud agent drop baseline on the legacy stream is **2** (stable across
  19,482 → 56,700 accepted). The **factory** agent (fed by the full `:1880` output)
  reports **0 unmapped drops** — strong evidence a `:1880`-fed cloud agent would also
  be ~0.
- **Cloud cutover mechanics — SAFE & REVERSIBLE.** `/etc/nginx/conf.d/cpack-ingest.conf`
  (server `:8447`, `cpack-ingest.staging.packiot.app`) currently: `location = /v1/tags`
  → `proxy_pass http://172.18.0.38:9104` (+ internal mirror → `172.18.0.4:9104` =
  SBXCPACK sandbox ent 2000003). No `/v2/tags` exists yet. The plan's Step-2 add +
  Step-4 `return 444` flip are one-`nginx -s reload` operations, instantly revertible.
- **`/v2` tee ingest key** = **`pk_cpack_af247745a1669a72bd82d70094a47d1588153422b03a4e6d`**
  (cloud agent `AGENT_INGEST_API_KEY`) — **distinct** from the factory reader's
  `CPACK_INGEST_KEY=4c867b6a…`. The Step-1 tee node must send the **cloud** key, not the
  factory one.

## Exact remediation for P0 (do before re-attempting the cutover)

1. **Fix the reader-flow generator** so the L6 (and any repeated-block) `modbus-read`
   nodes get **unique ids** (`{tenant}_mb_{plc}_read_{0..N}`), not a recycled `_read_{0,1}`.
2. Regenerate / hand-patch the running flow so **all 8** L6 `modbus-read` nodes are live,
   keep `quantity=2` + the 32-bit low-word-first combine, and set **PTH/Consumed @100 to
   `HoldingRegister`** (the running flow has `InputRegister`; `cpack.plc.yaml` says
   `kind: holding`).
3. **Persist** the corrected flow to the seed `cpack-reader-flow.json` **and** the repo
   (the running `/data/flows.json` diverged and is not codified).
4. **Verify** all 8 L6 members emit 32-bit matching the oracle magnitudes above
   (BREYER ≈291.8M, POLYTYPE ≈283.5M, RMH ≈104.2M gross, TEXA ≈266.0M) before touching
   nginx.
5. Only then run Steps 1–4 (tee `:1880` → `:8447/v2/tags` with the **cloud** ingest key;
   add nginx `location = /v2/tags`; verify cloud agent `total_dropped` stays flat and F3
   ent-3 advances; flip `/v1/tags` → `return 444`), and Step 5 per-line vs oracle, with
   the one-reload revert armed.

## Instant revert (unchanged from plan)

Nothing was changed, so no revert is needed now. When the cutover is later applied, the
one-reload revert is: restore `location = /v1/tags { proxy_pass http://172.18.0.38:9104; … }`
and `nginx -s reload`.
