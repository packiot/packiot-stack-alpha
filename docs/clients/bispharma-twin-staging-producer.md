# Bispharma (ent 5) — codified staging TWIN producer (GAP-1 proper fix)

**What / why.** Bispharma-Staging (`id_enterprise = 5`, SparkPlug group
`BISPHARMASTAGING`) had **no live data producer** — its factory box is offline and
`silver.equipment_values` for ent 5 froze at `2026-09-13 11:20:12 UTC` (~26 h stale by
the time of this fix). This is **GAP-1** of the production-readiness punch-list
(`bispharma-production-readiness-punchlist.md`). The 242 k rows that had landed came from
an **uncodified one-shot replay** that did not survive the redeploy — the exact
non-durability the punch-list warns against.

This is the punch-list's **"proper fix (a)"**: a **durable, codified twin/replay
producer** — the sibling of CPACK's twin-injector — so ent 5 gets a continuous OEE feed
**independent of the offline box**.

## The pattern it models — CPACK's twin-injector

| | CPACK twin | Bispharma twin |
|--|--|--|
| Code | `services/sparkplug-decoder/cmd/inject-counter-fixture` | `services/sparkplug-decoder/cmd/bispharma-twin` |
| Transport | SparkPlug B **NBIRTH + NDATA straight to Mosquitto** (`tcp://mosquitto:1883`) | same |
| Group | `CPACK` | `BISPHARMASTAGING` |
| Decoded by | shared `sparkplug-decoder` (subscribes `spBv1.0/#`) → `stream-engine` → `silver` | same |
| Shape | one-shot, one hardcoded metric | **long-running**, full line topology, monotonic totalizers, re-birth on NCMD |
| Semantics | single counter | **counters-only** (no state/speed): gross/net/scrap member totalizers |

**Why direct-to-Mosquitto, not the `:8449` rawtag front-door.** The rawtag path
(`ingest.staging.packiot.app:8449` → shared `sparkplug-agent`) is **not reachable from
inside the VPC** — the app box cannot hairpin its own public ingest SG (verified: a POST
from the app box to `:8449` returns HTTP `000`). Publishing SparkPlug straight to the
internal Mosquitto broker is the **same internal path CPACK's twin uses**, is proven to
decode (CPACK/`inject-test`), and removes nginx/SG/TLS from the loop.

## What it emits

Parameterized at boot from the **same tenant config the shared agent loads**
(`docs/clients/tenants/bispharma.yaml` → `TWIN_TENANT_CONFIG`). For the configured line
(`TWIN_LINE`, default `L01`) it selects every **member** count-index leaf of the form

```
/SP/LINHAS/<LINE>/<MEMBER>/Admin/Prod{Consumed,Processed,Defective}Count/<idx>/Unit
```

and emits a monotonically-increasing absolute totalizer for each. Using the
`raw_tag_map` (the generated allowlist, itself derived from the `count_index` map in
`docs/clients/tenant-profiles/bispharmastaging.yaml`) guarantees every metric name
resolves to a real member equipment id that lands in silver — never an unmapped drop.

For **L01** that is 18 leaves (6 members × 3 kinds) → equipment ids:

| member | index | id_equipment |
|--|--|--|
| S1INFEED | 168 | 2000225 |
| S3 | 164 | 2000226 |
| S4 | 165 | 2000227 |
| S5 | 166 | 2000228 |
| S6OUTPUT | 167 | 2000229 |
| SCRAP | 2000230 | 2000230 |

Gross (`ProdConsumedCount`) ≥ net (`ProdProcessedCount`), scrap = gross − net, all
monotonic — so it never trips the physics-invariant clamps. **No** `MachSpeed` /
`StateCurrent` (Bispharma is counters-only; `counters_only_oee=true`).

## How it's wired

- **Binary:** `services/sparkplug-decoder/cmd/bispharma-twin` (built + shipped by the
  `services/sparkplug-decoder/Dockerfile`, CGo-free).
- **Compose service:** `bispharma-twin` in `compose.staging.yml`, static IP `172.18.0.46`.
- **Two gates, both OFF by default:**
  1. compose profile `bispharma-twin` — never started on a default bring-up.
  2. `BISPHARMA_TWIN_ENABLED` (default `false`) — the binary no-ops + exits 0 unless
     explicitly `true`. **Primary guard.**
- **Tunables (env):** `BISPHARMA_TWIN_LINE` (L01), `BISPHARMA_TWIN_INTERVAL_SEC` (15),
  `BISPHARMA_TWIN_RATE_PER_MIN` (600), `BISPHARMA_TWIN_SCRAP_RATE` (0.03).

Enable on staging:

```bash
BISPHARMA_TWIN_ENABLED=true docker compose -f compose.staging.yml \
  --profile bispharma-twin up -d bispharma-twin
```

## ⚠️ DOUBLE-SOURCE GUARD — the one rule that matters

When the **real** Bispharma factory box comes back online it publishes the **same group**
(`BISPHARMASTAGING`) → the **same equipment ids**. Running this twin **at the same time**
as a real feed **DOUBLE-COUNTS every totalizer** (the classic two-writer bug —
`feedback_bug_two_writer_line_double_count`). **The twin MUST be disabled the moment a
real BISPHARMASTAGING feed is wired.**

- The twin carries a **distinct `edge_node_id`** (`bispharmastaging-twin`) so twin rows
  are identifiable in the decoder logs (`publisher "BISPHARMASTAGING/bispharmastaging-twin"`)
  — but that only makes them *distinguishable*, it does **not** prevent the double-count.
  **Disabling the twin is the guard.**
- **STAGING ONLY.** Never point this at a production broker.

To disable: `docker compose -f compose.staging.yml --profile bispharma-twin down` (or set
`BISPHARMA_TWIN_ENABLED=false` and recreate).

## Hardproof (2026-09-14, staging)

Ran the twin on the app box (built from branch, same golang:1.25-alpine pattern as CPACK's
twin-injector), `BISPHARMA_TWIN_ENABLED=true`, `TWIN_INTERVAL_SEC=10`:

- **Decoder** decodes it: `publisher=BISPHARMASTAGING/bispharmastaging-twin`, `metric_count=18`,
  `first_metric=.../S1INFEED/.../ProdConsumedCount/168/Unit`.
- **silver.equipment_values ent-5 lag = 6 s → 2 s** across successive reads (was ~26 h
  frozen); member ids 2000225–2000230 landing + advancing monotonically.
- **stream-engine** declares + consumes `stream-engine-q-bispharmastaging`
  (`tenants:[bispharmastaging,cpack,sbxcpack]`); silver writes confirm consumption.
- **OEE computes** for L01 line **2000224**: `gold.equipment_oee_hourly` @ 13:00 →
  `oee_a`/`oee_p`/`oee_q` non-zero, `gross=109 net=211`.
- **read-api canonical dataset** `serving.oee_score(5, …)` (what `/v1/query oee-score-full`
  serves) returns a **non-empty ent-5 row**: `id_equipment=2000224, oee_a>0, oee_p=1, oee_q=1,
  gross=109, net=109, running_time=50`.

## Related

- `bispharma-production-readiness-punchlist.md` — GAP-1 (this), and the remaining gaps
  (GAP-3 L90/S1INFEED clamp remap, GAP-4 scrap-capability, GAP-2 user seed) that need this
  live feed to validate against.
- `sbxcpack-sandbox-twin-single-source.md` — the sibling single-source discipline for the
  SBXCPACK sandbox twin (`oeecloud-fanout`).
