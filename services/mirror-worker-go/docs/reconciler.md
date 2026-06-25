# EnsureActivePOs reconciler — operator runbook

## What it is

A periodic loop inside `mirror-worker-go` that keeps staging's set of CPACK production orders in sync with prod, AND keeps their production counters tracking prod's values. Two passes on independent cadences:

| Pass | Cadence | What it does |
|---|---|---|
| **Existence** | every 5 min (`RECONCILE_INTERVAL_SEC`) | diffs prod active POs vs staging active POs by `id_order`; POSTs `/api/production-orders/create` + `/start` for any missing one; persists the mapping in `mirror_id_map`. |
| **Value sync** | every 30 s (`RECONCILE_VALUES_INTERVAL_SEC`) | for each mapped active CPACK PO, inserts one `equipment_values` row carrying the `(prod − staging)` net/gross delta. The per-minute pg_cron sums equipment_values into `production_orders_runtime` and the staging counter snaps to prod. |

## Why it exists

`mirror-worker-go`'s cursor-driven replay only sees ~5% of prod CPACK PO lifecycle. Most CPACK POs are created and started by PLC SparkPlug parameter writes (30800–30899) that oeecloud-node-red turns into stored-proc calls — they never hit edge-api, so the audit middleware never writes a `user_logs` row, so the mirror has nothing to replay. Session 67 measurement: in 24h, 6 CPACK POs created + 21 started → only 1 + 1 emitted `user_logs`. Without this reconciler, staging silently drifts away from prod's active set.

Even after we close the existence gap, staging's `production_orders_runtime.net_production` was computed from synthetic simulator `equipment_values` data — visible counters had no relationship to real prod values. Mixing simulator data with reconciler deltas would not give reproducible state, so the simulator now skips CPACK entirely (`SIM_SKIP_ENTERPRISE_IDS=3` default) and the reconciler is the sole writer of `equipment_values` for CPACK equipment.

## Architecture invariant

> **For any CPACK equipment row in `packml_register`, there is exactly one writer of `equipment_values`: the reconciler.**

If you violate this — by re-enabling the simulator for CPACK, or by adding another producer to the CPACK queue — the pg_cron job will sum BOTH sources and counters will run hot. The system reports this as a hard-to-debug "staging values higher than prod" symptom, not as an explicit error.

## Configuration (env vars)

| Variable | Default | Purpose |
|---|---:|---|
| `RECONCILE_ENABLED` | `true` | Master kill-switch for the whole reconciler |
| `RECONCILE_INTERVAL_SEC` | `300` | Existence pass cadence |
| `RECONCILE_MAX_PER_RUN` | `20` | Per-pass cap on the existence backfill — so a bad run can't hammer edge-api |
| `RECONCILE_VALUES_ENABLED` | `true` | Kill-switch for the value-sync pass only |
| `RECONCILE_VALUES_INTERVAL_SEC` | `30` | Value-sync cadence. Must be ≤ the cron interval (60 s) to stay ahead. |
| `SIM_SKIP_ENTERPRISE_IDS` | `3` (CPACK) | Tenants the simulator MUST NOT generate PLC traffic for. Comma-separated. |

## What you see in logs

```
{"msg":"reconciler starting","interval_sec":300,"max_per_run":20}
{"msg":"value sync starting","interval_sec":30}

# existence pass with drift:
{"msg":"reconciler pass: backfilling missing POs","prod_active":11,"staging_active":8,"drift":3,"processing":3}
{"msg":"reconciler: backfilled active PO","prod_po":1642045,"staging_po":12623,"id_order":892830}
{"msg":"reconciler pass complete","elapsed":584ms}

# existence pass when in sync:
{"msg":"reconciler pass: in sync","prod_active":11,"staging_active":11,"elapsed":70µs}

# value sync each tick:
{"msg":"value sync tick complete","mapped":11,"synced":9,"skipped":2,"elapsed":210ms}
```

Skipped during value sync = either the prod runtime row was NULL (cron hasn't computed it yet on prod side) OR delta was 0 (already in sync).

## Prometheus metrics

```
mirror_worker_reconciler_runs_total{outcome="ok|failed"}
mirror_worker_reconciler_pos_total{outcome="created|failed|skipped"}
mirror_worker_reconciler_active_drift_pos     # gauge — should settle to 0
mirror_worker_reconciler_values_synced_total{outcome="ok|failed"}
```

Healthy steady state:
- `active_drift_pos` = 0
- `runs_total{outcome="ok"}` increments every 5 min
- `values_synced_total{outcome="ok"}` accumulates ~22/min (11 active POs × 2 syncs/min, modulo "already in sync" skips)
- `pos_total` only ticks when prod creates a new PO

## When something goes wrong

### "active_drift_pos" stays > 0

Existence pass can't backfill some POs. Common causes:
1. **Equipment not in `packml_register` on staging** — the translator's lookup fails. Check `mirror-worker-go` logs for `no staging packml_register row for topic`.
2. **Per-pass cap exceeded** — drift > `RECONCILE_MAX_PER_RUN`. The pass takes ≤ 1s, the cap exists for safety only; bump it if you have legitimate drift > 20.
3. **edge-api 400 on create** — usually a missing site/area mapping. Check the `create POST` error in worker logs.

### Staging values run higher than prod

Almost always means the simulator is generating CPACK data. Verify:
```
docker logs stack-simulator-1 2>&1 | grep "skipping enterprise IDs"
# Expected line on simulator boot:
# "PLC simulation: skipping enterprise IDs [3] (mirror-managed)"
```

If that line is missing, `SIM_SKIP_ENTERPRISE_IDS` was overridden — restore the default `3`.

### Staging values run lower than prod by a fixed amount

Value sync is failing for one direction. Check `values_synced_total{outcome="failed"}` and the worker log for the `value sync: insert delta failed` warning. Usually a transient DB issue; if it persists, the equipment_values schema may have drifted and an INSERT column is now NOT NULL.

### Cron is overwriting my deltas

It shouldn't (cron READs equipment_values + WRITES production_orders_runtime; we WRITE equipment_values). If you see staging value drop unexpectedly, somebody else is INSERTing into equipment_values for CPACK equipment. Check:
```sql
SELECT DISTINCT id_enterprise, COUNT(*)
  FROM equipment_values
 WHERE ts_value > now() - interval '5 minutes'
 GROUP BY 1;
```
For id_enterprise=3 you should see ~22 rows/5min (11 active POs × 2 syncs/min × 5min). Significantly more means another writer.

## Manual triggers

There's no admin endpoint today, but you can fire a one-off sync:
```bash
docker exec mirror-worker-go ./mirror-worker-go --reconcile-once  # NOT IMPLEMENTED YET, TODO
```
For now, just restart the worker — its boot triggers an immediate existence pass + value sync.

## Disabling temporarily

```yaml
# compose.staging.yml
environment:
  RECONCILE_ENABLED: "false"          # disables both passes
  RECONCILE_VALUES_ENABLED: "false"   # disables only the value sync
```

If you disable the value sync without ALSO re-enabling the simulator for CPACK, staging CPACK counters will go flat (no source data). That's fine if you're debugging.

## Future work

- Add an /admin endpoint to trigger a sync without restart.
- Per-tenant scaling — if other production tenants get the same mirror treatment, the source name + enterprise IDs need to become a list, not a singleton.
- Drift visibility on the Grafana mirror dashboard (`/d/mirror-worker`) — current panels show cursor lag and replay rate but not active-PO drift.

## See also

- [`project_staging_cpack_data_source.md`](../../../.claude/projects/-home-podesta-github-packiot-packiot-stack-alpha/memory/project_staging_cpack_data_source.md) — why this exists + the 5%-ceiling math
- [`CLAUDE.md` at repo root](../../../CLAUDE.md) — PackML parameter ids + edge-api PO control endpoints
- Session 67 PRs: existence reconciler (#74), value-sync + simulator skip (this PR)
