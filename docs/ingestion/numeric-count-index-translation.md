# Numeric-count-index translation layer — design + staging validation

**Status:** Built · flag-gated (default OFF) · **Date:** 2026-07-27 · **Task:** #13 / #54 ·
**Governs:** [ADR-0045 §2.3 Option-B](../adr/0045-client-onboarding-architecture.md),
[canonical model §2](../clients/bispharma-bisnago-canonical-model.md) ·
**Code:** `services/edge-transformer/internal/agent/numeric`,
`internal/agent/httpingest` (`POST /v1/counters`), `cmd/sparkplug-agent` (flag),
`cmd/numeric-sim` (staging driver).

> **The USER directive:** *"a proper translation layer between plc → mqtt → go
> sparkplug → go transformer."* This is that layer for the pre-SparkPlug
> **numeric-counter** clients (bispharma, bisnago): the client edge stays a DUMB
> forwarder of `counterData[{id,value}]`, and the **stack** translates each
> numeric id → the canonical SparkPlug metric. Reusable for every numeric-counter
> tenant.

---

## 1. The problem

Bispharma (ent 4) and bisnago (ent 119) are **greenfield, counters-only, absolute
totalizers, zero customizations** (legacy-inventory §0/§4). Their legacy edges emit
**no topic strings** — just DINT counter values keyed by a bare numeric id
(bispharma 124..685; bisnago 670..683). Everything downstream of the Go
`sparkplug-agent` speaks **one** canonical SparkPlug shape (ADR-0032). So somewhere
the numeric id must become `ENTERPRISE/SITE/AREA/LINE/MEMBER/Admin/ProdProcessedCount/<idx>/Unit`.

Per ADR-0045 §2.3 **Option-B**, that "somewhere" is **stack-side, in the Go agent** —
not in per-client low-code. The tee forwards raw PLC facts faithfully; the agent
owns the canonicalization. This keeps the mapping a **versioned, tested, reviewed
stack artifact** instead of a transform re-typed into each factory's flow.

## 2. The translation layer (`internal/agent/numeric`)

```
DUMB tee ──counterData[{id,value}]──▶ agent POST /v1/counters
        (absolute totalizers)              │
                                           ▼  numeric.Translator
                     legacy id 164 ──▶ /LINHAS/L01/S3/Admin/ProdProcessedCount/164/Unit
                                           │  (canonical SUFFIX + type; ABSOLUTE value)
                                           ▼  the SAME sink /v1/tags uses
                    resolver → tagstore(RBE) → session → SparkPlug encode → uplink
                                           ▼
                    cloud edge-transformer decode → counters-only Calc → OEE
```

**How the id→canonical table is derived (zero new data).** The agent already
builds its `raw_tag_map` (the allowlist of canonical metric SUFFIXES) from the
tenant profile / `packml_register`. For a numeric-counter tenant every count leaf
is `.../<X>Count/<idx>/Unit`, and that `<idx>` **is** the descriptor's
`count_index.value` = the legacy numeric id the tee forwards. So the translation
table is a **pure function of the finalized `raw_tag_map`**
(`numeric.BuildIndexFromTagMap`): extract the integer `<idx>` out of every
count-leaf suffix → `idx → (suffix, type)`. This guarantees **by construction**
that every translated tag lands on a suffix the resolver already accepts — a
translated counter can never be dropped for a reason the `raw_tag_map` didn't
already surface. Duplicate indices are a fail-closed error.

**Absolute totalizer, not delta.** The legacy flow also computes a per-poll
`increment`; the translation **ignores it** and forwards the ABSOLUTE `value`. The
stack recomputes its own delta and applies the ADR-0037 per-equipment
**SANITY CLAMP** (#622), so delta ownership stays in one place (the Silver
invariant), never split across edge + stack.

**Unmapped ids are reported, not swallowed** (ADR-0045 §2.4a reject-don't-drop):
`Translate` returns the sorted/deduped set of unmapped ids; the agent bumps
`sparkplug_agent_numeric_unmapped_total` and the `/v1/counters` 202 body carries
`unmapped_index`.

## 3. Flags (all default OFF, reversible)

| Flag | Where | Effect |
|---|---|---|
| `AGENT_HTTP_INGEST_ENABLED=true` + `AGENT_INGEST_API_KEY` | sparkplug-agent | mounts the HTTP front-door (existing) |
| `AGENT_NUMERIC_INGEST_ENABLED=true` | sparkplug-agent | **mounts `POST /v1/counters`** + builds the translation table from `raw_tag_map` (fatal if empty) |
| `AGENT_TAGMAP_FROM_REGISTER=true` + `AGENT_PROFILE_PATH` | sparkplug-agent | builds `raw_tag_map` from `packml_register` + profile (else static agent.yaml) |
| `COUNTERS_ONLY_OEE_ENABLED=true` + `COUNTERS_ONLY_IDEAL_RATES=<eq:rate,…>` | edge-transformer Calc | counters-only Performance from rated speed (#591) |
| `COUNTERS_ONLY_AVAILABILITY_ENABLED=true` + `COUNTERS_ONLY_AVAILABILITY_EQUIPMENTS=<ids>` | oeecloud-worker | inferred Availability from counter activity (#600) |
| `INCREMENT_SANITY_CLAMP_ENABLED=true` | oeecloud-worker | per-equipment totalizer-delta clamp (#622) |

## 4. Staging validation

### 4.1 Deterministic e2e proof (automated, in CI)

`internal/agent/httpingest/counters_e2e_test.go` (`TestE2E_NumericCounters_TranslateToCanonicalSparkplug`)
drives a BISPHARMA-shaped `counterData` POST through **the exact cloud-side code**
(`POST /v1/counters` → translate → shared sink → `session.Build{NBIRTH,NDATA}` →
`sparkplug.Encode` → `sparkplug.Decode` → `StateStore.Ingest`) and asserts:

- id `164` → `BISPHARMA/SP/LINHAS/L01/S3/Admin/ProdProcessedCount/164/Unit` at the
  cloud decoder, **Double**, with the **absolute** advanced value (40355), so the
  stack can derive delta 40355−40321=34;
- id `167` likewise; an unmapped id `999` is **reported** (`unmapped_index:1`), not
  crashed;
- report-by-exception fires (2 changed counters between polls).

`internal/agent/numeric/artifacts_test.go` pins the **real generated `agent.yaml`**
artifacts translator-compatible: **bispharma → 91** translatable count indices,
**bisnago → 14** (legacy ids 670..683). A descriptor edit that breaks the numeric
layer fails CI.

### 4.2 Live staging run (with `cmd/numeric-sim`, no client edge needed)

`numeric-sim` IS the client's dumb tee, synthesized — it POSTs monotone absolute
totalizers keyed by legacy count id to a running agent's `/v1/counters`:

```bash
# on the staging box, against the bispharma agent's ingest port (9104)
numeric-sim --url https://localhost:9104/v1/counters --key "$AGENT_INGEST_API_KEY" \
  --group BISPHARMA --gateway bispharma-edge \
  --ids 164,165,166,167,168,169 \   # L01's members (a couple of lines' worth)
  --polls 6 --interval 5s --start 40000 --step 30 --insecure
# --reset-at N exercises the totalizer-reset → delta-clamp path (#622)
```

### 4.3 Shadow-DB verification (SELECT-only, done 2026-07-27)

On `packiot_analytics` (F3), `BEGIN TRANSACTION READ ONLY`:

| Check | Result |
|---|---|
| bispharma fresh block `id_equipment ∈ [40001,40191]` | **0 rows — FREE** |
| bisnago fresh block `id_equipment ∈ [41001,41114]` | **0 rows — FREE** |
| legacy `id_equipment ∈ [670,683]` (NEOPAC collision surface) | **0 rows** in shadow (the collision is legacy-PROD `tsp12` only) |
| existing bispharma/bisnago enterprise | **0 rows — not yet seeded** |

→ The fresh 40xxx/41xxx surrogate blocks are collision-free on the actual staging
target; **no NEOPAC (ent-13) risk**. Bisnago's `count_index.value` keeps the legacy
id 670..683 (the tee's routing key, safely namespaced under BISNAGO) while every
`id_equipment` is a fresh 41xxx surrogate — the real collision surface is avoided.

## 5. What a real go-live still needs (residual gates)

1. **Seed the staging tenant** — apply `docs/clients/gen/<tenant>-register.sql`
   (into a fresh staging enterprise surrogate) + set `equipments.production_speed`
   (rated speed — the one counters-only Performance input, NEEDS-CLIENT; use the
   documented placeholder in tenant-prep, ADJUSTABLE).
2. **Deploy a per-tenant `sparkplug-agent`** (one instance per tenant, ADR-0045
   §2.6) with `AGENT_HTTP_INGEST_ENABLED` + `AGENT_NUMERIC_INGEST_ENABLED` +
   the ingest key; enable `COUNTERS_ONLY_OEE_ENABLED` (+ ideal rates),
   `COUNTERS_ONLY_AVAILABILITY_ENABLED`, `INCREMENT_SANITY_CLAMP_ENABLED` for the
   tenant.
3. **CAPTURE** — bisnago's indices are `inferred`; a live tee must confirm them and
   resolve the **2-ids-per-line** meaning (2 machines vs processed+consumed) before
   `onboard-gen --cutover` will emit (it refuses on any inferred index).
4. **Point the client's dumb tee** at the staging (then prod) `/v1/counters`
   front-door — the only client-edge change, forwarding `counterData[{id,value}]`.
5. **Parity gate** — 0 unmapped ids for expected equipment + OEE ∈ [0,1] over a
   shift cycle (Mode-A parity, ADR-0022) before the reversible per-tenant cutover.

## 6. Sensible defaults used (all ADJUSTABLE)

| Default | Value | Why / how to change |
|---|---|---|
| bispharma prefix / site | `BISPHARMA/SP` | flow carries no topic strings; confirm site code |
| bisnago prefix / site / area | `BISNAGO/SP/LINHAS` | synthesized; confirm with client |
| bisnago id_equipment block | `41001..41007` (lines), `41101..41114` (members) | fresh, NEVER 670..683; reassign from a free staging block in tenant-prep |
| bisnago 2-ids-per-line | **both registered as members** (M`<id>`) | safest (nothing dropped, reversible); assign real OEE role on client confirmation |
| bisnago dormant lines | **excluded** (only 7 active `.7.x`) | reversible; re-add the 12 `.5.x` on client confirmation |
| count_index confidence | bispharma **confirmed** (flow emits `id:<N>`), bisnago **inferred** | bisnago needs a live-tee CAPTURE before cutover |
| rated speed | tenant-prep placeholder | set `equipments.production_speed`; NEEDS-CLIENT |
