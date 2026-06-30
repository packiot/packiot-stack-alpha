# EnsureActivePOs reconciler — operator runbook

## What it is

A periodic loop inside `mirror-worker-go` that keeps staging's set of CPACK production orders in sync with prod, keeps their production counters tracking prod's values, AND keeps the equipment_events history mirrored 1:1 so operator-action replay always has a target. Three passes on independent cadences:

| Pass | Cadence | What it does |
|---|---|---|
| **Existence** | every 5 min (`RECONCILE_INTERVAL_SEC`) | diffs prod active POs vs staging active POs by `id_order`; POSTs `/api/production-orders/create` + `/start` for any missing one; persists the mapping in `mirror_id_map`. |
| **Value sync** | every 30 s (`RECONCILE_VALUES_INTERVAL_SEC`) | for each mapped active CPACK PO, inserts one `equipment_values` row carrying the `(prod − staging)` net/gross delta. The per-minute pg_cron sums equipment_values into `production_orders_runtime` and the staging counter snaps to prod. |
| **Events sync** | every 60 s (`RECONCILE_EVENTS_INTERVAL_SEC`) | fetches prod `equipment_events` past the events-cursor, INSERTs each into staging with `forced_creation_system=true` (bypasses the dedup trigger), persists the mapping. Restores the equipment_events history that vanished when value-sync became the sole writer of equipment_values. |

## Why it exists

`mirror-worker-go`'s cursor-driven replay only sees ~5% of prod CPACK PO lifecycle. Most CPACK POs are created and started by PLC SparkPlug parameter writes (30800–30899) that oeecloud-node-red turns into stored-proc calls — they never hit edge-api, so the audit middleware never writes a `user_logs` row, so the mirror has nothing to replay. Session 67 measurement: in 24h, 6 CPACK POs created + 21 started → only 1 + 1 emitted `user_logs`. Without this reconciler, staging silently drifts away from prod's active set.

Even after we close the existence gap, staging's `production_orders_runtime.net_production` was computed from synthetic simulator `equipment_values` data — visible counters had no relationship to real prod values. Mixing simulator data with reconciler deltas would not give reproducible state, so the simulator now skips CPACK entirely (`SIM_SKIP_ENTERPRISE_IDS=3` default) and the reconciler is the sole writer of `equipment_values` for CPACK equipment.

## Architecture invariants

> **(1) For any CPACK equipment row in `packml_register`, there is exactly one writer of `equipment_values`: the value-sync pass.**
>
> **(2) For any CPACK equipment row in `packml_register`, there is exactly one writer of `equipment_values.equipment_events`: the events-sync pass.**

If you violate (1) — by re-enabling the simulator for CPACK, or by adding another producer — the pg_cron job will sum BOTH sources and counters will run hot. Hard-to-debug "staging values higher than prod" symptom.

If you violate (2) — by reintroducing state/mode/speed-bearing equipment_values writes for CPACK, or by re-enabling the simulator for CPACK — `piot_trig_equipment_events_update_prev` will fire on the foreign writer, producing equipment_events that the events-sync didn't author. The dedup branch may also reject the reconciler's INSERTs on the next prev_status match, leaving holes in the mirror. (We sidestep the dedup branch via `forced_creation_system=true` on our INSERTs, but a foreign writer wouldn't.)

## Configuration (env vars)

| Variable | Default | Purpose |
|---|---:|---|
| `RECONCILE_ENABLED` | `true` | Master kill-switch for the whole reconciler |
| `RECONCILE_INTERVAL_SEC` | `300` | Existence pass cadence |
| `RECONCILE_MAX_PER_RUN` | `20` | Per-pass cap on the existence backfill — so a bad run can't hammer edge-api |
| `RECONCILE_VALUES_ENABLED` | `true` | Kill-switch for the value-sync pass only |
| `RECONCILE_VALUES_INTERVAL_SEC` | `30` | Value-sync cadence. Must be ≤ the cron interval (60 s) to stay ahead. |
| `RECONCILE_EVENTS_ENABLED` | `true` | Kill-switch for the events-sync pass only |
| `RECONCILE_EVENTS_INTERVAL_SEC` | `60` | Events-sync cadence. 60 s ≈ "matcher cache hit before the next operator action lands". |
| `RECONCILE_EVENTS_BATCH_SIZE` | `200` | Per-tick cap on prod `equipment_events` rows pulled. Cold-start backlog drains over multiple ticks. |
| `SIM_SKIP_ENTERPRISE_IDS` | `3` (CPACK) | Tenants the simulator MUST NOT generate PLC traffic for. Comma-separated. |
| `DLQ_RETRY_ENABLED` | `true` | Kill-switch for the DLQ retry loop |
| `DLQ_RETRY_INTERVAL_SEC` | `300` | DLQ retry cadence (5 min) |
| `DLQ_RETRY_MAX_ATTEMPTS` | `5` | Per-row attempt cap. Backoff schedule: +1m, +2m, +4m, +8m, +16m. After 5, row stays in DLQ for human inspection. |
| `DLQ_RETRY_BATCH_SIZE` | `50` | Per-pass cap on rows examined — a giant DLQ backlog can't hammer edge-api in one tick |
| `COMPARATOR_ENABLED` | `true` | Kill-switch for the comparator fidelity-watchdog loop (ADR-0008 phase 2a) |
| `COMPARATOR_INTERVAL_SEC` | `300` | Comparator cadence (5 min). Matches existence reconciler — comparator watches what reconciler maintains. |
| `COMPARATOR_OEE_INTERVAL_SEC` | `1800` | OEE divergence sub-cadence (30 min). Gated internally inside the comparator loop — heavier query, longer interval. Doesn't add a goroutine. |

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

# events sync starting + first tick:
{"msg":"events sync starting","interval_sec":60,"batch_size":200,"cursor_at_boot":2450158586}
{"msg":"events sync tick complete","cursor_from":2450158586,"cursor_to":2450158602,"fetched":16,"created":14,"skipped":2,"failed":0,"elapsed":340ms}

# DLQ retry tick:
{"msg":"DLQ retry starting","interval_sec":300,"max_attempts":5,"batch_size":50}
{"msg":"DLQ retry succeeded — row deleted","dlq_id":287,"source_log_id":2502318,"category":"event-justified","attempts_used":1}
{"msg":"DLQ retry tick complete","examined":3,"succeeded":3,"failed":0,"permanent":0,"elapsed":120ms}
```

Skipped during value sync = either the prod runtime row was NULL (cron hasn't computed it yet on prod side) OR delta was 0 (already in sync).

Skipped during events sync = either the equipment isn't in `packml_register` on staging (logged at WARN with prod_equipment_id) OR a mapping already exists for the prod event id (idempotency hit from a prior pass).

## Prometheus metrics

```
mirror_worker_reconciler_runs_total{outcome="ok|failed"}
mirror_worker_reconciler_pos_total{outcome="created|failed|skipped"}
mirror_worker_reconciler_active_drift_pos     # gauge — should settle to 0
mirror_worker_reconciler_values_synced_total{outcome="ok|failed"}
mirror_worker_reconciler_events_total{outcome="created|failed|skipped"}
mirror_worker_reconciler_events_cursor        # gauge — monotonically increases
mirror_worker_dlq_retry_attempts_total{outcome="succeeded|failed|permanent"}
mirror_worker_dlq_depth                       # gauge — should hover near zero
mirror_worker_comparator_active_pos_diff      # gauge — should be 0 (prod-staging diff)
mirror_worker_comparator_runs_total{outcome="ok|failed"}
mirror_worker_comparator_events_lag_seconds   # gauge — should be < 120s
mirror_worker_comparator_user_logs_lag        # gauge — should be tiny
mirror_worker_comparator_oee_divergence_pct{id_production_order}  # gauge per active PO — should be < 0.01
mirror_worker_comparator_oee_measured_total{outcome="ok|skipped|failed"}
mirror_worker_comparator_dlq_anomaly_total    # gauge — should be 0
```

Healthy steady state:
- `active_drift_pos` = 0
- `runs_total{outcome="ok"}` increments every 5 min
- `values_synced_total{outcome="ok"}` accumulates ~22/min (11 active POs × 2 syncs/min, modulo "already in sync" skips)
- `pos_total` only ticks when prod creates a new PO
- `events_cursor` monotonically increases at roughly prod's events-emission rate (~10–50 per minute during a normal CPACK shift)
- `events_total{outcome="created"}` accumulates near `events_cursor` delta; `skipped` is non-zero only when packml_register is missing an entry; `failed` should be ~0
- `comparator_active_pos_diff` = 0 (prod count == staging count for active POs)
- `comparator_runs_total{outcome="ok"}` increments every 5 min; `failed` ratio should stay low
- `comparator_events_lag_seconds` < 120s (events-sync reconciler cadence is 60s; one tick of lag is normal)
- `comparator_user_logs_lag` < 100 (worker's main poll cursor stays within ~100 IDs of prod's max)
- `comparator_oee_divergence_pct{id_production_order}` < 0.01 for every label (1% is within rounding noise for the per-minute pg_cron cycle)
- `comparator_oee_measured_total{outcome="ok"}` increments every 30 min; `skipped` non-zero is expected when freshly-started POs have prod.net_production=0
- `comparator_dlq_anomaly_total` = 0 (every staging DLQ entry has a matching prod user_log)

## Comparator (fidelity watchdog, ADR-0008 phase 2a)

Periodic SELECT-only loop that runs alongside the reconcilers. Where reconcilers WRITE to staging to close gaps, the comparator READS both systems to MEASURE residual gaps. It validates that the reconciler is doing its job; the two together form the writer + watchdog pair.

**Dashboard.** All 6 comparator gauges + the runs-rate counter render in the **Comparator — fidelity watchdog** row on the existing `/d/mirror-worker` Grafana dashboard (`grafana/dashboards/07-mirror-worker.json`). Each stat panel uses the thresholds documented in this runbook's healthy-state checklist (green/yellow/red bands). Alert-rule provisioning (Slack/ntfy/email delivery) is intentionally NOT in source today — the colorized panel thresholds catch divergence at a glance during operator review; a follow-up will wire alert rules once the team picks a delivery mechanism.

Phase 2a.1 ships one metric: `comparator_active_pos_diff`. Future phases (2a.2-2a.5) add 4 more: `events_lag_seconds`, `oee_divergence_pct{po}`, `dlq_anomaly_total`, `user_logs_lag`. Each plugs into the same RunOnce loop via a new measure-function.

### When the comparator alerts

#### `comparator_active_pos_diff` consistently non-zero

1. **Verify the comparator itself isn't broken.** Check `comparator_runs_total{outcome="failed"}` — if non-zero recently, the comparator couldn't query one of the two systems. Look at the worker log for `comparator measure failed`.
2. **Identify direction.** Positive = prod has more (EnsureActivePOs reconciler is behind). Negative = staging has stale rows (something didn't close on staging). Sign tells you which side to investigate first.
3. **Cross-check with `active_drift_pos`.** The two gauges measure the same underlying state from different angles — if they disagree, the reconciler's drift calculation is wrong.
4. **Look at the reconciler.** Is the existence pass running? When was its last `reconciler pass complete`? Has it logged any failed PO creates or `reconciler: revived existing staging PO` lines?
5. **Only then start digging into the data.** Most divergence is explained by step 3-4 before you need to inspect individual POs.

#### `comparator_events_lag_seconds > 300` sustained

1. **First, check `comparator_events_lag_seconds` isn't stale.** The gauge intentionally doesn't update when prod has no events in the last hour (idle line) — confirm prod's max(ts_event) is recent by querying directly.
2. **Check the events reconciler.** Is `RECONCILE_EVENTS_ENABLED=true`? When did `events sync tick complete` last log? Is `reconciler_events_cursor` advancing?
3. **Check `reconciler_events_total{outcome="failed"}`.** If non-zero rate, the reconciler is failing to write — usually a FK violation from a missing staging packml_register row. Add the row (CS Admin path) and re-arm.
4. **If reconciler looks healthy, check for trigger drift.** The events reconciler uses `forced_creation_system=true` to bypass dedup; if a schema migration broke that bypass, writes would silently fail. Check trigger function source against the runbook invariants.

#### `comparator_user_logs_lag` growing without bound

1. **The worker is stalled on the main poll loop.** Check `dispatcher` activity — `mirror_worker_user_logs_polled_total` rate should match prod's publish rate.
2. **Check the most recent handler outcomes.** If `mirror_worker_user_logs_replayed_total{outcome="failed"}` is climbing, a handler is consistently erroring and the cursor isn't advancing past those rows. Inspect the DLQ.
3. **Check for a stuck row inside the per-row tx.** Long-running `processRow` invocations (e.g. blocked on a staging DB write) hold the cursor at the row before them. `pg_stat_activity` on staging shows the blocked statement.

#### `comparator_oee_divergence_pct{id_production_order}` > 0.05 for one PO

1. **Single PO divergence is usually a value-sync gap on that specific equipment.** Check whether the reconciler's value-sync has been seeing the equipment — `mirror_worker_reconciler_values_synced_total{outcome="failed"}` rate is the right signal, but it's not labeled by equipment; cross-check via worker log search for `value sync: insert delta failed` near the affected PO.
2. **Look at the underlying equipment_values rate on both sides.** If prod is producing equipment_values at a different rate than staging is receiving them, the value-sync delta will lag. Use the existing `mirror_worker_reconciler_values_synced_total` against the period.
3. **Check for an OEE-trigger drift on staging.** The pg_cron job `piot_proc_refresh_runtime` rebuilds `production_orders_runtime` every minute on staging; if it errored on the affected PO, staging's net_production won't advance even with healthy equipment_values inserts.

#### `comparator_oee_divergence_pct{id_production_order}` > 0.05 for many POs simultaneously

Likely a systemic value-sync outage, not per-PO. Check `mirror_worker_reconciler_values_synced_total` rate vs the period of the divergence — if the synced count dropped, the value-sync is broken or disabled. `RECONCILE_VALUES_ENABLED=true`?

#### `comparator_dlq_anomaly_total` > 0

Real-world rare. Staging has DLQ rows whose `source_log_id` no longer exists in prod's `user_logs`. The DLQ retry loop will mark these as "permanent" forever (the prod row is gone, can't replay). Resolution requires manual triage:

```sql
-- Find which staging DLQ entries are orphans:
SELECT id, source_log_id, category, error, created_at
  FROM mirror_replay_dlq d
 WHERE d.source = 'cpack-prod-go'
   AND NOT EXISTS (
     -- Query prod via a separate connection (this is just illustrative)
     SELECT 1 FROM user_logs WHERE id_user_logs = d.source_log_id
   );

-- After verifying the rows are truly orphaned (the prod user_log really is gone),
-- DELETE them. They cannot be replayed; keeping them only inflates DLQ depth.
DELETE FROM mirror_replay_dlq WHERE id = $N;
```

Common causes:
1. **Prod data cleanup.** A scheduled prune on prod `user_logs` (retention policy, GDPR delete, etc.) removed rows that staging's DLQ still references.
2. **Wrong ID stamped at DLQ-write time.** A bug in `processRow` recorded the wrong `source_log_id` — extremely unlikely but auditable via the DLQ row's `created_at` + git blame.
3. **Race with prod's DBA-led row removal.** Prod admin manually deleted user_logs rows (e.g. cleaning test data).

### Why a separate loop, not merged into the reconciler

Comparator failures should never block reconciler writes (and vice versa). Splitting at the goroutine boundary keeps their failure modes independent. The reconciler can be busy; the comparator can be querying tsp12; one's success doesn't gate the other's tick.

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

### DLQ filling with `equipment_event NNN unmapped (no staging interval overlap)`

After PR retiring event-justified / event-edited / event-splitted handlers, this symptom should no longer appear from operator-action replay — those categories are no longer dispatched (the events-sync reconciler is the sole writer of equipment_events, per invariant 2 above). If you still see it, it's coming from `downtime-event-created`, which carries an equipment_event reference and still needs the matcher:

```sql
-- Is the events reconciler producing mappings at all?
SELECT entity_type, COUNT(*) FROM mirror_id_map
 WHERE source = 'cpack-prod-go' GROUP BY entity_type;
-- equipment_event should be the largest bucket after a few hours of runtime.

-- Where is the events cursor relative to the prod event id in the DLQ?
SELECT source, last_log_id FROM mirror_replay_cursor
 WHERE source = 'cpack-prod-go-events';
```

If `events_cursor` is far behind the prod event id in the DLQ, the events reconciler is broken or disabled. Check `RECONCILE_EVENTS_ENABLED` + the worker log for `events sync starting`.

If `events_cursor` is past the prod event id and the mapping is still missing, the equipment's `packml_register` row is absent on staging — the events reconciler logged "equipment unmapped, skipping". Fix the staging packml_register row, then either restart the worker or wait for the next user_logs replay to retry the matcher.

### A DLQ row is stuck at retry_attempts=5

The retry loop has given up on this row — it failed 5 times in a row across ~31 minutes of backoff. Inspect it by hand:
```sql
SELECT id, source_log_id, category, error, created_at, retry_attempts, last_retry_at
  FROM mirror_replay_dlq
 WHERE retry_attempts >= 5
 ORDER BY id DESC LIMIT 20;
```
Most permanent-stuck rows fall into one of three categories:
1. **Entity unmapped** — equipment/site/area missing from `packml_register` or `sites`/`areas`. Add the entity on staging, then `UPDATE mirror_replay_dlq SET retry_attempts = 0, last_retry_at = NULL WHERE id = $X` to re-arm the row.
2. **Edge-api 400 / business-rule rejection** — e.g. "Production order can not be stopped" when the staging PO is in a non-running state. May indicate prod-vs-staging state drift; usually safe to delete the row after inspection.
3. **Schema drift** — payload references a column edge-api no longer accepts. Fix the migration, redeploy edge-api, re-arm the row.

### DLQ depth keeps climbing

If `mirror_worker_dlq_depth` is monotonically increasing, the retry loop isn't winning. Causes in priority order:
1. Edge-api unreachable on the docker network → check `docker exec mirror-worker-go nc -zv edge-api 8080`
2. New systemic failure mode → look at `mirror_worker_dlq_retry_attempts_total{outcome="failed"}` rate-of-increase vs `succeeded`; if failed >> succeeded for >15min, the retry loop is just stamping `retry_attempts++` without progress
3. Staging DB write contention → check `pg_stat_activity` for long-running INSERTs blocking the per-row tx

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
