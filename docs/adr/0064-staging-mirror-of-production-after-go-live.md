# ADR-0064 — After a tenant's production go-live, staging is a read-only mirror of production

**Status:** Accepted (user requirement 2026-10-15) — built, **off**; switched on in Bispharma's go-live window ·
**Date:** 2026-10-15 · **Decision owner:** user
**Trigger (user, 2026-10-15):** *"make sure that no conflicts will exist and staging reflects the production state"* —
Bispharma (enterprise 5) goes live on the new production stack; a second box instance on Bispharma's VM feeds
production while the existing one keeps feeding staging (go-live runbook, `release/prod-promotion-2026-10`).

---

## 1. Problem

After the go-live two systems receive the same PLC data for enterprise 5. If operators or CS act on **both** (PO
start/stop, justify/split, manual stops, targets, config edits in csadmin/customize, box scans, samples, users),
staging and production diverge, and nobody can tell which one is right.

**Requirement:** production is the single source of truth. Staging's enterprise 5 mirrors it and never conflicts.

## 2. Decision

| # | Decision |
|---|---|
| D1 | **One switch.** `PROD_MIRROR_ENTERPRISES=5` in staging's `/opt/packiot/.env` turns on everything below (edge-api, barcode-service, stream-engine, prod-reflector). Unset everywhere until the window; unset again on rollback. A typo fails the boot of every service (it must never silently re-open writes) |
| D2 | **Every write on staging is refused for a mirrored tenant** — deny by default. edge-api: every POST/PUT/PATCH/DELETE → 403 `MIRROR_TENANT_WRITE_BLOCKED` with *"read-only mirror of PRODUCTION … make this change in production: <url>"* (exemptions: read-only POSTs and box sessions, each with a reason). barcode-service: scans → 403. `GET /api/environment/mirror-status` drives a read-only banner in operator, front4, csadmin and customize |
| D3 | **State reflection, not action replay.** A new staging service, **prod-reflector**, converges staging's rows of the tenant to production's every minute, table by table; production always wins. Same schema and same ids on both sides (production was built from staging), so copying state is strictly simpler than re-executing actions — and it heals itself: an outage, a missed pass or a stray write is undone by the next pass |
| D4 | **What is reflected: everything production owns.** Configuration, users/roles, POs + runtime, events + justifications/splits/manual stops, box scans, samples, **and OEE (gold) + live views**. **Local to staging:** the raw series from staging's own reader (`bronze.*_raw`, `silver.equipment_values`, `silver.plc_link_minutes`, `silver.equipment_live_metrics`), its audit log, its invariants. Staging's engine skips the tenant in every job that writes a reflected table |
| D5 | **Names and keys.** Staging's enterprise is named *production's name + " (mirror)"* — **"Bispharma (mirror)"** — set by the reflector, so a person always sees which environment they are in and a production rename follows. `api_key` is never copied (staging keeps its key and its box keeps posting with it; production rotates its own); the reflector's role cannot even UPDATE that column |
| D6 | **Id blocks.** Production mints every id ≥ **1,000,000,000** (`PROD_ID_BLOCK`, set by the go-live `seq-floor.sql`); staging's sequences stay below it. A row copied from production can never collide with a row staging minted for another tenant. Invariant MR4 checks both sides |
| D7 | **Least privilege, secrets on the hosts.** Production side: `prod_reflector_ro` — SELECT on the reflected tables only, `default_transaction_read_only=on`, NOBYPASSRLS, tenant stamped per connection. Staging side: `prod_reflector` — DML on the reflected tables only. Passwords generated on each host (`provision-db-role.py`); staging's app role may read exactly one production secret |
| D8 | **Network:** a VPC peering staging ↔ production (same account/region), one route each way (staging app → production DB `/32`), one DB SG ingress (5432 from the staging app's private IP). Terraform written, **planned, not applied** |

## 3. Options considered for the replication (D3)

| Option | Verdict | Why |
|---|---|---|
| (a) Replay production's `identity.user_logs` (as legacy-replicator does for CPACK) | rejected | Re-executes business logic on staging and needs id mapping for every derived row (legacy-replicator: 1,342 lines of handlers + PO/event/manual reconcilers, because the legacy schema differs). Misses everything that never passes through `user_logs` (engine-minted stops, PLC-driven POs, migrations, CS SQL) — the CPACK mirror needed three reconcilers to close those holes |
| (b) Logical replication / CDC | rejected | TimescaleDB hypertables cannot be published; a replication slot on **production** retains WAL while staging is down (production disk risk); `wal_level=logical` needs a production restart; row filters cannot express "rows of equipment of enterprise 5"; subscriber triggers (cagg invalidation) are off by default; PG16 → PG15 |
| **(c) Periodic convergence ("heal from production")** | **chosen** | The sandbox-heal model across two databases: per table, per day bucket, compare `count + md5` of the tenant's rows on both sides, fetch only differing buckets, upsert/delete by primary key, read back. Stateless, idempotent, self-healing, SELECT-only on production, works through outages, catalog-driven |

**Cost measured on staging's real catalog (2026-10-15):** every generated statement ran (read-only) against
`packiot_analytics`; a hot pass (35-day window) fingerprints 2.2 s per side, a full pass 2.5 s, dominated by
`gold.equipment_oee_hourly` (200 k rows). Interval 60 s, full pass every 6 h.

## 4. Conflict sweep — every place the two environments could disagree

| Risk | Prevention |
|---|---|
| Operator PO start/stop/setup/replace, justify, split, manual stops on staging | edge-api 403 (D2); operator banner; reflector undoes anything that slips through and counts it (`prod_reflector_staging_writes_total`, alert ProdMirrorStagingWrites) |
| CS edits in csadmin/customize (hierarchy, topics, device keys, descriptors, reasons, targets, shifts, out-of-service, users/roles, i18n, promote, teardown) | edge-api 403 — deny by default, the spec walks **every** controller (a new route is blocked until someone decides otherwise); teardown also protects the tenant |
| CS edits on staging through a DB console (CloudBeaver/pgweb) | Not blockable by the apps; the reflector reverts within a minute and alerts (staging-write detector). Rule in the runbook: never edit enterprise 5 on staging |
| Box scans / samples on staging | barcode-service 403; samples/labels routes 403 in edge-api; `bispharma-box-scan-mock` stays off (`BISPHARMA_BOX_SCAN_MOCK_ENABLED` default false) |
| Two engines minting the same stop twice / closing stops differently | staging's engine skips the tenant (`CPAC_EVENT_LIVE`, `CPAC_EVENT`, `EVENTS_CLOSE_STALE` minus 5); production's stops are copied with their justifications |
| Two OEE computations from two readers' slightly different samples | staging takes production's gold (rollups, backfill, UNS views, PO recalc skip the tenant). Staging's own reader still fills `silver.equipment_values` (minute charts, and the rollback base) — minute-grain charts on staging show staging's reader; every hour/shift/day number is production's |
| PLC-driven PO commands (30800+) read by both readers | stream-engine po-control skips a mirror tenant |
| **PO numbers** | The client PO number is unique per enterprise (ADR-0062); staging cannot create POs for the tenant, so only production assigns numbers |
| **Sequences / ids** | D6: production ≥ 1e9, staging < 1e9 (MR4). Staging's highest id in a reflected table today: 601,633,961 (sandbox POs = legacy id + 500 M); natural-key tables (events: `(id_equipment, ts_event)`) need no block |
| **Idempotency keys** | `ops.idempotency_keys` is per environment, not reflected; no write of the tenant reaches staging's edge-api, so no key is consumed there. `box_scans.scan_uuid` and `po_uuid` (UUIDv7) are global and copied as-is |
| **Cognito users** | One shared pool (`us-east-1_0T9t1sTwt`). A Bispharma user logs in to **both** with the same identity; `identity.users` is reflected, so a user CS creates in production also exists on staging (read-only there). Users get the **production** URLs (`front.prod`, `operator.prod`); the staging URLs keep working and show the read-only banner |
| **API keys** | Separate per environment (D5). Production's rotated key never exists on staging; staging's box keeps the staging key; operator-bispharma on staging keeps its key (reads only) |
| **ERP/SAP exports** (`SHIFT06`, `SAP13`, `SYNC06`, `BOXES13`, box bridges) | None is configured for enterprise 5 (customer ids 6/13; `core.box_production_bridges` has 0 rows for 5). Rule: never configure an integration for a mirror tenant on staging; `customer_reports.*` are Local (not reflected) and the engine's PO/rollup exclusion keeps their inputs untouched |
| **Superset reports** | Each environment embeds its own Superset over its own DB (`bi.staging` / `bi.prod`). Staging's reports now show production's numbers (gold is reflected) — no double counting because the two never merge |
| **Slack / alerting** | Separate Alertmanagers. Staging's data invariants for enterprise 5 now describe a mirror (MR1–MR5 added); production pages for the real tenant. The staging box instance's own alerts (reader link, ingest) stay meaningful: they watch staging's reader |
| **Barcode cloud instance** | One barcode-service per environment; Bispharma's scanners are pointed at production's barcode endpoint at the go-live; staging's refuses enterprise 5 with 403, so a scanner left on staging fails loudly instead of recording a scan production never sees |
| **Box helper / agent names** | Already separated by the go-live overlay: `packiot-*-prod` containers, project `packiot-prod`, helper port 1890, no fat-edge tee. Staging Box Ops (still allowed) only ever touch `/opt/packiot` |
| **Historian** | Staging's historian keeps enterprise 5's cold history up to the go-live; after it, what it exports from staging is production's numbers (reflected) plus staging's own raw series. **Keep it** (it is the long-term copy until production gets its own historian); production's own historian is a separate follow-up |
| **Table added later** | Every tenant-keyed table must be Reflected or Local (`spec.go`); an unclassified one is reported (MR5, alert) and not touched |
| **Schema drift during a deploy window** | Only columns present on both sides are compared and written; a column on one side only is reported, never fails the pass |
| **Production looks empty (lost RLS stamp, revoked grant)** | `empty_source` guard: no deletes when production returns 0 rows for a table staging has rows in; `max_deletes` (2000/table/pass); a production without the enterprise row aborts the pass |

## 5. Invariants and alerts

`ops.data_invariant_result` every 15 min (source `prod-reflector`): **MR1** configuration tables equal (critical),
**MR2** POs/runtime/box counters equal (critical), **MR3** last converged pass ≤ 10 min (critical), **MR4** id blocks
hold on both sides (critical), **MR5** no unclassified tenant tables (warn). Prometheus: ProdMirrorStale (15 min),
ProdMirrorGuarded, ProdMirrorStagingWrites, ProdMirrorUnclassifiedTables.

## 6. Switching on, and rollback

Go-live runbook §6 (release branch) and [staging-mirror-of-production.md](../runbooks/staging-mirror-of-production.md):
T-1 apply the migration + roles + terraform (peering, SG, IAM) and dry-run the reflector against the live production
stack; T-0 set `PROD_MIRROR_ENTERPRISES=5` **before** the staging extract (the snapshot is then final: nothing can be
written on staging between the extract and the switch), recreate four services.

**Rollback (production rolled back):** remove the line, recreate the four services. Staging becomes the master again
with everything production did until then (it was mirrored); its engine resumes the tenant from the next hour (its
own `silver.equipment_values` is complete, so any hour can be recomputed if wanted); writes reopen. Rename it back to
`Bispharma-Staging` if wanted.

## 7. Consequences

- Staging no longer exercises the engine on Bispharma's data (production does); CPACK (ent 3) and the sandbox twin
  remain the engine's test beds. A Bispharma sandbox twin is the follow-up if that is needed.
- The reflector is generic (`PROD_MIRROR_ENTERPRISES` is a list): CPACK's own production go-live reuses it.
- Bonus finding: `seq-floor.sql` floored production at the **old** production DB's maxima, but legacy CPACK keeps
  minting ids after that snapshot, so CPACK's later go-live could have collided with Bispharma's new ids. The 1e9
  block (D6) removes that class too.
