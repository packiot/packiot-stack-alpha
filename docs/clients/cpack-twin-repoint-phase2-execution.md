# CPACK twin re-point (legacy :1881 → new-stack :1880) — Phase-2 EXECUTION

**Date:** 2026-08-25 · **Outcome:** reader fix LIVE + cutover STAGED & PROVEN at the
ingest layer, but the **final /v1 cut was reverted** (idle production window prevented
per-line validation, and a stale cloud map needs a proper redeploy). Twin is back on
legacy, healthy. This doc is the precise state + the exact remaining steps.

## What is LIVE now (kept)

- **Corrected reader (#907) deployed to `:1880`** (`edge-cpack-nodered`, factory
  10.135.1.173). Replaces the old dup-node-id flow. **VERIFIED**: all 5 L6 members now
  emit full 32-bit totalizers matching the packiot40 oracle (previously only L6/TEXA
  polled — 7 of 8 modbus reads were shadowed by duplicate ids):
  | member | emitted | oracle |
  |---|---|---|
  | BREYER/91 | 291,878,573 | 291,789,977 |
  | POLYTYPE/93 | 283,618,366 | 283,532,648 |
  | PTH/95 | 272,397,368 | 272,312,800 |
  | RMH/94 | 104,199,546 | 104,162,623 |
  | TEXA/92 | 266,125,490 | 266,042,525 |
  This also **fixes prod's L6** (it was reading 32-bit counters as 16-bit → wrapping at
  65535). Prod uplink to `ssl://ingest.prod:8883` verified intact after deploy.

## What was REVERTED (twin cutover machinery — all backed out)

nginx `/v2`, the reader staging-tee, and a cloud-map patch were added, proven, then
**fully reverted**. Final live state = pristine: nginx `/v1` proxy_pass restored (no
`/v2`, no `return 444`), cloud agent on its original 102-entry map, twin fresh on legacy.

## What we PROVED works (the cutover is viable)

1. **Reader staging-tee → cloud** works: a 2nd wire off the reader's `normalize` fn
   re-POSTs the rawtag envelope to `https://cpack-ingest.staging.packiot.app:8447/v2/tags`
   with `X-Ingest-Key: pk_cpack_af247745…` (the **cloud** agent key, distinct from the
   factory's `4c867b6a…`). Confirmed **202** at nginx `/v2`.
   - Gotcha: the tee's http-request node must send `msg.headers` (mirror the prod node);
     and the tee function node MUST have an output wire (a missing wire = fn fires, no POST).
2. **nginx `/v2`** = `location = /v2/tags { proxy_pass http://172.18.0.38:9104/v1/tags; …same block as /v1… }` — one reload, reversible.

## The BLOCKER that forced the revert: the deployed cloud map is STALE

The running `sparkplug-agent-cpack` mounts **`docs/clients/cpack-agent.yaml`** (old path,
102 entries, `packml_topic: CPACK/SC/LINHAS`, L4 member indices **88/89/86/87/84**). But
#907 codified the **correct** map at **`docs/clients/edge-deployment/cpack/cpack-agent.yaml`**
(330 entries, `packml_topic: CPACK/SC`, `/LINHAS/…` suffixes, L4 indices **6/7/8/9/10**,
+ full CELULA/SLEEVE/FLEXO coverage). Under the stale map, :1880's `/v2` stream dropped:
- **5 LINHAS/L4 member counts** (reader emits idx 6/7/8/9; stale map expects 88/89/86/87)
  → **would regress L4** (a live-patch of +5 L4 entries fixed this and L4 members flowed).
- **~25 CELULA/SLEEVE/FLEXO count suffixes** — out of scope for the stale map; the twin
  never had these via legacy, so dropping them is **not a regression** (but the #907 map
  DOES cover them → a potential new win).

**The stale map is NOT a wholesale swap**: the #907 map file carries a *factory* sparkplug
config (`uplink_broker: ssl://ingest.prod:8883`, mTLS). The cloud twin agent must uplink to
the **internal mosquitto** instead. The correct artifact is committed here as
`cpack-agent.twin.yaml` (= #907 map + `uplink_broker: tcp://mosquitto:1883`, TLS refs
blanked; `packml_topic: CPACK/SC` kept — the published topic `CPACK/SC/LINHAS/L6/…` is
identical to the old map's `CPACK/SC/LINHAS`+`/L6/…`, so downstream id_equipment
resolution is unchanged).

## Second finding: idle-window RBE masked validation

After cutting `/v1`, F3 ent-3 went ~11 min without writes. Root cause: the agent uses
**RBE** (SparkPlug report-by-exception — publish only on value change); the **factory
agent (prod) was ALSO nearly flat (+1 publish/15s)** → production was **idle** (~12:45
BRT lunch). Legacy masks idle by writing frequently regardless. So the "staleness" was
correct RBE behaviour, not a broken pipeline — but it means the cut can't be validated
during idle. **The final cut must be done during ACTIVE production.**

## Third finding (separate, downstream): L4/L8/L10 LINES don't compute on the twin

Even with members flowing (both feeds), lines **49/L4, 51/L8, 52/L10** have no
`equipment_values`, while the oracle has them — and net values cross-wire (oracle L10 net
= twin L3 net; oracle L8 net = twin L3 gross). This is a **downstream OEE line-config /
packml_register count-index resolution** issue for ent-3, **independent of the ingest
cutover** — it will not be fixed by cutting `/v1`. Needs its own investigation
(lead_machine / infeed-outfeed linkage + count-index → id resolution for L4/L8/L10).

## EXACT remaining steps to complete the cutover (during active production)

1. **Deploy the cloud-twin map**: put `cpack-agent.twin.yaml` (this dir) at the cloud
   agent's `/etc/packiot/agent.yaml` (repoint the compose mount, or replace the mounted
   file), `docker restart sparkplug-agent-cpack`. Verify healthy + uplink
   `tcp://mosquitto:1883`. Expected `/v2` drops → **0**.
2. **Re-add** nginx `/v2` + the reader staging-tee (`cpack-staging-tee-node.json` here).
3. **Verify** `/v2` 202s, agent `total_dropped` flat, and — **while machines produce** —
   F3 ent-3 advances for all :1880-fed indices.
4. **Cut** `/v1` → `return 444`, reload.
5. **Per-line vs oracle** over a producing window; revert `/v1` on any regression.
6. Separately, fix the **L4/L8/L10 line-computation** downstream gap.

## Instant revert (still armed on the box)

- nginx: `/etc/nginx/conf.d/cpack-ingest.conf.bak.pre-v2.*` and `.bak.pre-cut.*`
- reader flow: `~/flows.json.bak.1787667400` (original dup-id flow) on the factory box
- cloud map: `…/docs/clients/cpack-agent.yaml.bak.pre-l4.*`
