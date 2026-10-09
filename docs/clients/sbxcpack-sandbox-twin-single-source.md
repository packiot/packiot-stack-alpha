# SBXCPACK sandbox twin — single canonical source (fanout), native sim retired

**Date:** 2026-08-24 · **Env:** staging (`i-06c9547a2c7091ab7`) · **Tenant:** SBXCPACK = enterprise `2000003` (`SANDBOX-CPACK`)

## TL;DR

The SBXCPACK sandbox twin was **double-sourced**. It is now single-sourced from
`oeecloud-fanout` (the faithful re-tenanted mirror of real CPACK). The ad-hoc native
simulator (`sbx-feeder` + `sparkplug-agent-sbx`) was stopped, and the dead legacy
`sandbox_cpack` RabbitMQ queue + its stale `packml_register` rows were removed.
Real-CPACK enterprise `3` is untouched.

## The two producers (before)

SBXCPACK received data from **two independent producers**, both resolving to the same
`SBXCPACK/SC/...` topics → same equipments → the one queue
`stream-engine-q-sbxcpack` → `equipment_values` for ent `2000003`:

| Producer | What | Cadence | Coverage | Codified? |
|----------|------|---------|----------|-----------|
| **oeecloud-fanout** (KEEP) | re-tenants real CPACK (`CPACK`→`SBXCPACK`) on the `oee` exchange | 15 s (mirrors real CPACK) | **all** CPACK lines | yes — `compose.staging.yml`, `scripts/emit-fanout-config.sh`, `configs/fanout/sbxcpack.yml` |
| ~~sbx-feeder + sparkplug-agent-sbx~~ (RETIRE) | alpine `feeder.sh` → HTTP `:9104` → SparkPlug `SBXCPACK/sbx-tee` | 5 s | **L5 only** (5 synthetic machines) | **no** — hand-launched, in no compose/script |

### Proof of the double-feed (L5-BREYER, equip `2000053`)

`equipment_values` carried two interleaved streams with independent baselines — the
classic two-writer tell:

```
17:44:48  gross 4.693899e6  speed 108   (5 s cadence)  ← sim  (SBXCPACK/sbx-tee)
17:44:45  gross 606399      speed 72    (15 s cadence) ← fanout
17:44:43  gross 4.69389e6   speed 108
17:44:30  gross 606381      speed 68    ← fanout
```

The `606399` value at `17:44:45` is **byte-identical to real CPACK** `L5-BREYER`
(equip `53`) at the same instant → that stream is the fanout mirror. The `4.69M/108/5s`
stream is the sim (decoder log `publisher":"SBXCPACK/sbx-tee"`, seq every 5 s).

Cross-check over 10 min, machines active (row counts):

```
              CPACK ent3   SBXCPACK ent2000003
L10-PTH          7      =        7      ← fanout only, faithful
L3-POLYTYPE     19      =       19
L4-BREYER       19      =       19
L4-TEXA         19      =       19
L6-PTH           1      =        1
L5-BREYER       39      <      157      ← DOUBLE-FED (39 fanout + ~118 sim@5s)
L5-POLYTYPE     39      <      157
L5-RMH          37      <      155
```

Non-L5 lines already matched real CPACK exactly (single fanout source); only L5 diverged.

## Decision — fanout is canonical

- **Faithful:** fanout reproduces real CPACK values exactly (`606399 == 606399`); the sim
  emits synthetic totalizers (`~4.69M`) that match nothing.
- **Complete:** fanout carries every CPACK line; the sim covers L5 only.
- **Codified:** fanout is the designed config-as-data twin mechanism (task #22 —
  `emit-fanout-config.sh`, wired into `provision-sandbox-tenant.sh`); the sim is
  hand-launched drift, in no compose file or script.
- The user's goal is a *faithful replica of CPACK prod-legacy* → that is the fanout.

## Actions taken (all reversible)

1. **Stopped the native sim** (live, reversible):
   ```
   docker stop sbx-feeder sparkplug-agent-sbx
   ```
   Both are hand-launched (not in `compose.staging.yml` or any script), so the stop is
   durable across deploys/resets — nothing re-creates them.
   **Revert:** `docker start sparkplug-agent-sbx sbx-feeder`.

2. **Removed the dead legacy `sandbox_cpack` queue** (confusing name-overlap sibling;
   0 messages ever). It was backed by 17 stale `packml_register` rows under the OLD
   `SANDBOX_CPACK/SC/...` naming (malformed, trailing-slash, mostly empty
   `id_equipment`) — superseded by the live `SBXCPACK/SC/...` (118 rows). Both map to
   ent `2000003`; no producer ever emitted `SANDBOX_CPACK/...`.

   Order matters (prune source of truth → restart declarer → delete orphan):
   ```sql
   -- in BOTH packiot AND packiot_analytics (stream-engine discovery reads analytics post-F1-retirement)
   UPDATE packml_register SET active=false
   WHERE lower(split_part(packml_topic,'/',1))='sandbox_cpack' AND active;   -- 17 rows each
   ```
   ```
   docker restart stream-engine    # re-discovers → 11 tenants, no sandbox_cpack
   rabbitmqctl delete_queue stream-engine-q-sandbox_cpack{,-retry-30s,-failed}
   ```
   Verified it **stays gone** across 2+ discovery cycles.
   **Revert:** `UPDATE ... SET active=true` for register ids
   `packiot`: 4529,4530,4532,4534,4536,4539,4549,4552,4566,4569,4616,4628,4637,4651,4660,4668,4671 ·
   `packiot_analytics`: 635–651 — then restart stream-engine.

   Note: `WORKER_TENANT_ALLOWLIST=cpack,sbxcpack` (already deployed) is the durable guard
   that keeps foreign/cruft tenants (incl. a re-cut `sandbox_cpack`) out of the consume set.

## After — single coherent source

```
L5-BREYER SBXCPACK           real CPACK ent3 (source of truth)
18:53:00  607157   =   18:53:00  607157
18:52:46  607132   =   18:52:46  607132   ← identical, single 15s fanout stream
```
Decoder `SBXCPACK/sbx-tee` count in last 60 s = **0**. Fanout healthy. Every SBXCPACK
line now equals its real-CPACK counterpart → a clean faithful twin, no double-counting.

## Drivability of the sandbox (test-the-new-stack surfaces)

| Path | Status | Evidence / gap |
|------|--------|----------------|
| **OEE data feed → F3** | ✅ wired | fanout mirror of real CPACK (above) |
| **Operator action → edge-api → F3 write** | ✅ wired (write plane) | **Traced:** `POST /api/downtimes/create-manual-event` with the SBXCPACK api_key (`x-api-key: 120b6f46…`) → HTTP 201, row `equipment_events_man` id 160, **id_enterprise=2000003**, equip `2000053`; tenant fence passed; reversed via `delete-manual-event` (200). edge-api is multi-tenant by api_key — SBXCPACK is drivable. |
| **Operator SPA (UI-driven)** | ⚠️ CPACK-bound | The `operator` container is pinned to real CPACK ent-3 (`EDGE_API_KEY=fe1681…`, `REFDATA_API_KEY=stg-cpack-key`). UI actions hit ent-3, not the sandbox. To exercise the sandbox *through the UI*, run a second operator instance with `EDGE_API_KEY=<SBXCPACK api_key 120b6f46…>` + a refdata key scoped to 2000003. Write plane already proven above. |
| **csadmin → edge-api** | ✅ wired | edge-api CS-admin cross-tenant authz (`?idEnterprise=2000003`, Cognito `cs-admin` group) — same mechanism proven for onboarding; no per-tenant binding needed. |
| **front4 (read)** | per-user | read plane is single-tenant-per-user; needs a Cognito user resolving to 2000003 (same prerequisite as box-scan). |
| **Box scan → barcode-service → F3** | ❌ unwired | barcode-service derives tenant **strictly** from the JWT (`custom:id_enterprise` claim / Firebase users row) — no client-named tenant, no internal-key path. It is unused platform-wide (0 rows) because **no Cognito user carries `custom:id_enterprise`** (dev@packiot.com has only email/sub). Wiring plan below. |

### Box-scan wiring plan (bigger effort — not done live)

To make box-scans drivable into SBXCPACK end-to-end:

1. **Cognito user with the tenant claim** — create a sandbox scanner user in pool
   `us-east-1_0T9t1sTwt` with `custom:id_enterprise=2000003` and a permanent password.
   (Confirm the `custom:id_enterprise` attribute exists in the pool schema —
   `terraform/staging/cognito.tf`; the box IAM role can `list-users`/`admin-get-user`
   but not `describe-user-pool`, so verify via terraform.)
2. **Scan context** — `POST /v1/scans` requires `id_production_order` + `id_equipment`
   both owned by the tenant (`tenantOwns`). Provision an active PO on an ent-2000003
   scanning-station equipment (e.g. a machine under a sandbox line).
3. **Trace** — authenticate (SRP), `POST /v1/scans` `{scan_uuid, id_production_order,
   id_equipment, scan_type:"production", mode:"assign"}` → expect a `box_scans` row +
   `po_box_counter` bump for ent 2000003, `label_seq` server-assigned.

This is a discrete follow-up (identity + PO provisioning); the reversible parts (Cognito
user) can be added when box-scan testing is scheduled.

## Real-CPACK ent-3 untouched (proof)

- L5-BREYER (equip 53) kept advancing throughout (`608261 @ 18:04`, unchanged cadence).
- 11 machines active / 5 min — same set as before.
- `packml_register` for ent 3: fully active; its `equipment_events_man` unchanged.
- No fanout/sim/queue/register change touched the `cpack`/ent-3 namespace — only
  `sandbox_cpack` (a different prefix) was deactivated.
