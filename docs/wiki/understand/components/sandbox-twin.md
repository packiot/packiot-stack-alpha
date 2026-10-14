---
title: Sandbox twin (SANDBOX-CPACK)
layer: 3
owner_area: legacy-bridge
last_verified: 2026-10-14
---
# Sandbox twin (SANDBOX-CPACK)

> **Layer 3 · Components** — how the staging sandbox (enterprise 2000003) stays a copy of
> CPACK-Staging (enterprise 3), how a hands-on change holds it, and how the heal resets it.
> For engineers writing E2E tests or debugging the sandbox. Staging only.
> Up: [Legacy bridge](../subsystems/legacy-bridge.md) ·
> Testers' guide: [Sandbox for testing](../../use/sandbox-for-testing.md) ·
> Ops runbook: [docs/runbooks/sandbox-twin.md](https://github.com/packiot/packiot-stack-alpha/blob/staging/docs/runbooks/sandbox-twin.md)

## Responsibility

Give everyone a tenant where any write is allowed and is thrown away afterwards. The twin is
kept equal to CPACK-Staging by three feeds, frozen while a person is changing it, and reset
completely (a **heal**) to CPACK-Staging once the hands-on session's grace period is over.
Policy (2026-10-14): the heal resets **everything** it reflects, barcode box scans included.

## At a glance

| | |
|---|---|
| Tenant | `2000003` (`SANDBOX-CPACK`, Sparkplug group `SBXCPACK`), source enterprise `3` |
| Id mapping | config ids (sites, areas, equipment, users, …) = CPACK id + **2,000,000**; PO and PO-runtime ids = CPACK id + **500,000,000** |
| Feeds | telemetry: `oeecloud-fanout` (`CPACK` → `SBXCPACK`); operator actions: `legacy-replicator-sbx` (legacy ent 1 → 2000003); state: `ops.sandbox_reflect` at every heal |
| Heal entrypoint | `scripts/provision-sandbox-tenant.sh --heal`, called by `scripts/sandbox-session.sh` |
| Schedulers | `sandbox-grace-heal.timer` on the app host (every 5 min, `tick`); `.github/workflows/sandbox-selfheal.yml` cron `0 6 * * *` (`nightly`) and manual dispatch |
| State | `ops.sandbox_state` (grace, `hold_until`, last heal) and view `ops.sandbox_hold_status` |
| Apps that write to it | `operator-sbx` (its nginx injects the sandbox api-key), `barcode-app`, csadmin / customize / front4 with the sandbox selected |

## Inputs & outputs

| Direction | What |
|---|---|
| Reads | CPACK (ent 3) rows in `core.*`, `silver.equipment_events`, `silver.equipment_events_man`, `core.production_orders`, `gold.production_orders_runtime`, gold history; `identity.user_logs` of ent 2000003 (hold detection) |
| Writes (heal) | the ent 2000003 copies of those rows; deletes `gold.po_box_counter` and `bronze.box_scans` of ent 2000003 (once #1759's rollback is applied, see [History](#history)) |
| Not touched by the heal | `bronze.sample_boxes` (sample labels), `config.equipment_out_of_service`, QA users `qa-*@packiot.com`, the sandbox api-key, live telemetry and older history |

## Internal design

### A change holds the twin

edge-api's audit logger writes an `identity.user_logs` row for every request (for example
`scanned-box-recorded`, `sample-created`, PO and downtime actions, csadmin edits).
`ops.sandbox_is_change(category)` is true unless the category ends in a read suffix
(`-listed`, `-read`, `-viewed`, `_status`, …); **unknown categories count as changes** (a
spurious hold only delays a heal; a missed one would wipe someone's work).

```text
 write via edge-api ─► identity.user_logs (ent 2000003, category)
                         │ ops.sandbox_is_change(category) and ts_log > last_heal_at
                         ▼
 ops.sandbox_hold_status: held = true
   heal_due_at = greatest(last_change_at + grace, hold_until)      grace default 4 h
   ├─ legacy-replicator-sbx: ops.sandbox_hold_mode = 'session' → advance cursor, apply nothing
   ├─ provision --heal: ops.sandbox_heal_begin refuses (unless due or SANDBOX_HEAL_FORCE=1)
   └─ sandbox-grace-heal.timer (5 min): heal_due? → sandbox-session.sh tick → heal
```

A write that bypasses edge-api (direct SQL, barcode-service `POST /v1/scans`) writes no
`user_logs` row and does **not** hold the twin.

### The heal

`provision-sandbox-tenant.sh --heal`, in order:

1. `ops.sandbox_heal_begin(2000003, force)`: refuses while held and not due; sets `healing_since`
   (the replicator then **pauses** in `healing` mode so CPACK actions arriving mid-heal replay
   afterwards).
2. Config re-clone in the `packiot` DB from ent 3 (sites, areas, equipments, packml register,
   shifts, users except `qa-*`, descriptor), plus a wipe of ent-2000003 `scanned_boxes` and
   `production_orders` there.
3. Analytics DB: `ops.sandbox_drop_catalog_extras`, then
   `CALL ops.sandbox_reflect(3, 2000003, 2000000, interval '14 days', false)`: config upsert
   and extras deleted; events of the last 14 days restored from CPACK (undoes justify/split);
   all manual events; **all POs and runtimes swapped** (sandbox-native POs are deleted;
   twin PO ids are deterministic, CPACK id + 500,000,000); box counters and box scans of the
   tenant deleted before the swap.
4. `ops.sandbox_resync_gold_history` (pre-2026-09-01 months whose fingerprint differs) and
   `ops.sandbox_sync_attribution` (line meter roles and topic routing).
5. `ops.sandbox_fix_running_without_runtime(2000003)` (PRODT-164): a Running PO without an
   open runtime window gets one from the line's last runtime end when the line is free,
   otherwise it is paused. Refuses any enterprise below 1,000,000.
6. Refresh of `serving.downtime_events_resolved` for the last 15 days; QA users re-seeded;
   `ops.sandbox_heal_end` records the heal, clears `hold_until` and releases the hold.

Each optional step is guarded by `to_regprocedure(...)`, so an older DB just skips it.

### Live stops during a session

With `SANDBOX_HOLD_BASE_EVENTS=true` in `/opt/packiot/.env` (compose default `false`),
`legacy-replicator-sbx` keeps inserting PLC stops while the twin is held (insert-only, never
overwriting a tester's justification or split); a heal still pauses it.

## Configuration

| Knob | Where | Default | Effect |
|---|---|---|---|
| `grace` | `ops.sandbox_state` (action `grace`) | `4 hours` | time after the last change before the heal; persists across heals, applies to everyone |
| `hold_until` | `ops.sandbox_state` (action `extend`) | null | manual extension; cleared by the next successful heal |
| `SANDBOX_HOLD_ENABLED` | `legacy-replicator-sbx` | `true` on sbx | honour the hold modes |
| `SANDBOX_HOLD_BASE_EVENTS` | `/opt/packiot/.env` | `false` | keep inserting PLC stops while held |
| `SANDBOX_HEAL_FORCE` | env of `provision --heal` | `0` | `1` heals a held twin (what `heal-now` does) |
| `SANDBOX_LOCAL` | env of the scripts | unset | `1` = run psql on the app host (timer, runner) instead of via SSM |

## Operating it

Check the state (read-only, analytics DB `packiot_analytics`):

```sql
SELECT held, last_change, last_change_at, grace, hold_until,
       heal_due_at, heal_due, last_heal_at, last_heal_status, healing_since
  FROM ops.sandbox_hold_status
 WHERE id_enterprise = 2000003;
SELECT ops.sandbox_hold_mode(2000003);   -- none | session | healing
```

Or from a workstation with AWS access: `scripts/sandbox-session.sh status | extend 8h |
grace 4h | heal-now`, or the **Sandbox Self-Heal** workflow (actions `status`, `heal-now`,
`extend`, `grace`, `install`). `install` re-copies the scripts to `/opt/packiot/sandbox` and
refreshes the timer; run it after changing `provision-sandbox-tenant.sh` or
`sandbox-session.sh`. Timer logs: `journalctl -u sandbox-grace-heal.service`.

Use `sandbox-session.sh heal-now`, not `provision --heal` directly: a failed direct heal
leaves `healing_since` set, so the twin is not due again for an hour.

## Tests (E2E rules)

- Tests that write go to **2000003 only**. Never write to CPACK (ent 3): edge-api blocks
  operator writes there (`MIRROR_TENANT_WRITE_BLOCKED`), and anything that gets through
  fights the replicator and corrupts the CPACK comparison (2026-10-08: test POs took ~74k net).
- **Tag your test data** so a human can tell it apart: the suites use names such as
  `E2E-AREA-CRUD` and notes starting with `E2E`.
- `npm run test:sandbox` (in `e2e/`) heals first (`global-setup.ts` → `provision --heal`).
  If a person holds the twin, the heal refuses (exit 4) and the suite stops instead of wiping
  their session. `test:sandbox:noheal` skips the heal.
- After a run, `heal-now` releases the hold instead of leaving the twin held for 4 h.
- Logins come from Secrets Manager `packiot/staging/e2e-test-creds` (`npm run creds`):
  `SANDBOX_USER` = `qa-sandbox-staging@packiot.com`, `OPERATOR_SBX_URL` = `operator-sbx`.

## Failure modes

| Failure | Symptom | Cause | Fix |
|---|---|---|---|
| Heal fails on a catalog unique key (2026-09-30) | every heal fails | twin-native client or product with a CPACK name | `ops.sandbox_drop_catalog_extras` runs before the reflect |
| Heal fails on `po_uuid` (2026-10-08) | nightly heal fails | the reflect cloned a new UNIQUE column with `to_jsonb(x) || overrides` | reflect mints its own; grep the cloners before adding a UNIQUE column |
| pg_restore fails on `fk_po_box_counter_production_order` (2026-09-29) | restore drill fails | box counters whose PO vanished (FK triggers off during the swap) | tenant-wide delete of box counters and scans before the swap |
| Scans "not persisted" (2026-10-06) | testers' barcode scans gone the next day | the heal wipes box scans | by design since 2026-10-14; documented for testers |
| CPACK action lost (2026-09-30) | one CPACK stop never reached the twin | the replicator skipped during a heal | `healing` mode pauses instead of skipping (`t-sandbox-hold-mode`) |
| Twin never heals | `held` stays true | a later change (often an E2E run) moved the deadline | `status`, then `heal-now` |

## History

| Date | Change |
|---|---|
| 2026-09-30 | grace hold and timer (`t-sandbox-grace-hold`, `t-sandbox-hold-mode`) |
| 2026-10-14 | PRODT-164: `t-sandbox-running-po-runtime`, `SANDBOX_HOLD_BASE_EVENTS` |
| 2026-10-14 | #1759 made box scans survive heals; **reverted** the same day by user decision (the sandbox resets completely). The DB rollback is the migration's `rollback.sql`, applied on staging by hand; the revert PR is merged only after that |

## Source map

| Path | What's there |
|---|---|
| [`scripts/provision-sandbox-tenant.sh`](https://github.com/packiot/packiot-stack-alpha/blob/staging/scripts/provision-sandbox-tenant.sh) | create / reset / `--heal` / `--reset-data` / delete |
| [`scripts/sandbox-session.sh`](https://github.com/packiot/packiot-stack-alpha/blob/staging/scripts/sandbox-session.sh) | `status`, `extend`, `grace`, `heal-now`, `tick`, `nightly` |
| [`scripts/install-sandbox-grace-heal.sh`](https://github.com/packiot/packiot-stack-alpha/blob/staging/scripts/install-sandbox-grace-heal.sh), `systemd/sandbox-grace-heal.{timer,service}` | the 5-minute timer on the app host |
| [`.github/workflows/sandbox-selfheal.yml`](https://github.com/packiot/packiot-stack-alpha/blob/staging/.github/workflows/sandbox-selfheal.yml) | nightly 06:00 UTC + manual actions |
| `db/migrations/t-sandbox-reflection` | `ops.sandbox_reflect` |
| `db/migrations/t-sandbox-grace-hold`, `t-sandbox-hold-mode` | hold state, `sandbox_is_change`, `sandbox_hold_status`, heal begin/end, hold modes |
| `db/migrations/t-sandbox-reflect-catalog-extras`, `t-sandbox-attribution-sync`, `t-sandbox-reflect-line-roles`, `t-adr0062-sandbox-twin-po-uuid` | heal fixes and parity steps |
| `db/migrations/t-sandbox-running-po-runtime` | `ops.sandbox_fix_running_without_runtime` (PRODT-164) |
| `services/analytics-sync/internal/replicate/hold.go` | the replicator's hold gate |
| `e2e/global-setup.ts`, `e2e/.env.example` | E2E heal-first and sandbox credentials |
| [`docs/runbooks/sandbox-twin.md`](https://github.com/packiot/packiot-stack-alpha/blob/staging/docs/runbooks/sandbox-twin.md) | ops runbook, one-time enablement steps |
