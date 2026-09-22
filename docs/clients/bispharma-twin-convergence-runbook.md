# Bispharma (ent5) → codified twin convergence — MAINTENANCE RUNBOOK

**Status:** planned maintenance task (do NOT hot-swap under a live feed). Pairs with
[bispharma-twin-staging-producer.md](./bispharma-twin-staging-producer.md) (the twin
itself) — read that first.

## Goal
Retire the **uncodified `bispharmastaging-tee` replay** and make the **codified
`bispharma-twin`** the single ent5 producer, emitting **all 23 lines** with the
`#1378` **stop-simulation** (→ derived downtime events). This closes two demo gaps:
(1) empty Downtimes/Pareto, (2) 17 lines with no continuous feed.

## Why this needs a window (the risk that makes it non-trivial)
The current ent5 feed (`BISPHARMASTAGING/bispharmastaging-tee`) is produced by the
**shared multi-tenant `sparkplug-agent-shared`**, which transforms **external rawtag
POSTs** into per-group SparkPlug tees — and it produces **CPACK's `cpack-tee` from the
same process** (verified: both publish at the same cadence, ~36 msgs/3min). CPACK
(ent3) is a **live client whose Mission Control we just stabilised**. So:

- You **cannot** just stop the shared agent — that kills CPACK's feed too.
- Enabling the twin **alongside** the tee **double-counts** every overlapping line's
  totalizers (the two-writer bug — `feedback_bug_two_writer_line_double_count`). The
  tee feeds a **variable, cycling** set of ent5 lines (11+ observed across the SP and
  BISNAGOSP sectors), so there is **no stable non-overlapping subset** to scope a
  partial twin to safely.

**Therefore the only safe convergence is: stop the ent5 rawtag source, confirm the
tee is silent, THEN enable the twin.**

## Preconditions
- [ ] A maintenance window (ent5 OEE will have a short gap during the cutover).
- [ ] Confirm CPACK is healthy going in (baseline): `cpack-tee` flowing, current-shift
      OEE non-zero (see the verify queries at the end).
- [ ] Know who/what runs the external `BISPHARMASTAGING` rawtag replay (it POSTs to
      the public ingest front-door `ingest.staging.packiot.app:8449`, not a container
      on the app box). This is the thing to stop in step 1.

## Steps

### 1. Stop the ent5 rawtag source (pick ONE)
**Option A — stop the external replay (preferred; no CPACK impact).**
Find and stop whatever POSTs `BISPHARMASTAGING` rawtags to the ingest front-door
(a replay script / captured-data player). CPACK's `cpack-tee` keeps flowing untouched.

**Option B — drop the bispharma pipeline in the shared agent (if the replay can't be
reached).** Temporarily remove the tenant config so the agent rejects `BISPHARMASTAGING`
rawtags as unmapped:
```bash
# on the app box, in the deploy checkout
mv docs/clients/tenants/bispharma.yaml /tmp/bispharma.yaml.hold
docker compose -f compose.staging.yml -f compose.superset.yml -p stack \
  up -d --no-deps --force-recreate sparkplug-agent-shared
```
⚠️ This recreates the shared agent → a **few-second blip on CPACK's `cpack-tee`** too.
Acceptable inside a window; restore the file after the twin is proven if you want the
agent config back to baseline (the twin, not the agent, is ent5's producer now).

### 2. Confirm the tee is silent
```bash
docker logs --since 2m sparkplug-decoder 2>&1 | grep -c 'bispharmastaging-tee'   # want 0
# and ent5 silver stops advancing:
#   select max(ts_value) from silver.equipment_values v join core.equipments e
#     on e.id_equipment=v.id_equipment where e.id_enterprise=5;   (re-run: should stall)
```

### 3. Enable the codified twin (all lines + stop-sim)
```bash
# /opt/packiot/.env
BISPHARMA_TWIN_ENABLED=true
BISPHARMA_TWIN_LINE=ALL           # already the default here
# stop-sim is on by default (TWIN_STOP_PROB=0.03, 120-600s freezes) — the #1378 fix
docker compose -f compose.staging.yml -f compose.superset.yml -p stack \
  up -d --no-deps --force-recreate bispharma-twin
```

### 4. Verify the twin — the single writer, all 23 lines, WITH downtimes
```bash
# decoder now shows the TWIN edge node, not the tee:
docker logs --since 2m sparkplug-decoder 2>&1 | grep -oE '"publisher":"BISPHARMASTAGING/[^"]+"' | sort | uniq -c
#   want: bispharmastaging-twin  (NOT bispharmastaging-tee)
```
Then, against `packiot_analytics` (tenant-5 fenced where noted):
- **All 23 lines feeding:** `silver.equipment_values` fresh for ent5 members across
  every line (not just the 6/11 the tee covered).
- **Downtime events appear (the whole point):**
  `select count(*) from silver.equipment_events ev join core.equipments e
     on e.id_equipment=ev.id_equipment where e.id_enterprise=5
     and ev.ts_event > now()-interval '30 min';`  → **> 0** (was 0 forever).
- **OEE computes** per line in `gold.equipment_oee_hourly` (tp=3), a/p/q non-zero.
- **No double-count:** each ent5 equipment has exactly one writer — spot-check a line's
  totalizer is monotonic, not jumping by 2× (the guard the tee-stop in step 1 enforces).

### 5. Verify CPACK is unaffected
- `cpack-tee` still flowing (`docker logs --since 2m sparkplug-decoder | grep -c cpack-tee` > 0).
- CPACK current-shift OEE still non-zero (the `serving.mission_control` / `bi.oee_shift`
  checks from the rollup fix).

## Rollback
```bash
# /opt/packiot/.env
BISPHARMA_TWIN_ENABLED=false
docker compose ... up -d --no-deps --force-recreate bispharma-twin   # twin idles
# restore the external replay (Option A) or the tenant file (Option B):
mv /tmp/bispharma.yaml.hold docs/clients/tenants/bispharma.yaml   # if Option B
docker compose ... up -d --no-deps --force-recreate sparkplug-agent-shared
```

## Durability note
`bispharma-twin` is **always part of the `stack` project (no compose profile)**, so a
normal deploy keeps it running; the only state is the `BISPHARMA_TWIN_ENABLED` flag in
`/opt/packiot/.env`. To make the "twin-on" posture survive an instance replacement,
also set it in the codified env (terraform `app_init.sh` / the app secret), the same
way `SUPERSET_OEE_DASHBOARD_UUID_PT` is codified.

## Related
- `bispharma-twin-staging-producer.md` — the twin + the double-source guard.
- `feedback_bug_two_writer_line_double_count` — why two producers on one group corrupts data.
