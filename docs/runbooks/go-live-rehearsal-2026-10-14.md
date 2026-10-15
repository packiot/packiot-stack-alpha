# Go-live dress rehearsal — 2026-10-14

This was a full rehearsal of the production promotion (#1653, branch `release/prod-promotion-2026-10`). It ran against a
**throwaway clone of today's prod DB** with **today's staging schema**: transplant, swap, a deploy-shaped start of the
promoted services, smoke tests, rollback, and teardown.

**No production change was made:**
- no prod host, DNS, Terraform apply or client traffic;
- the legacy systems were not touched at all, not even read;
- staging got one read-only schema dump plus catalog reads.

Method and phases: [production-promotion-transplant-runbook.md](../adr/reference/production-promotion-transplant-runbook.md)
(on the release branch).

## Verdict

**NO-GO as the release branch stood this morning. CONDITIONAL GO once #1784 and #1782 are merged.** The rehearsal found
three defects that would have broken prod at the go-live:
- a Postgres **crash loop**;
- **read-api denied** on every continuous aggregate;
- a **failing grants step**: the roles were missing.

All three are fixed in #1784, and the third rehearsal run with those fixes was clean. What is left is user-owned (§6).

## 1. Delta since the 10-08 rehearsal

- **Release branch catch-up: #1780, MERGED** (`1ebbd19b`). The release branch was 236 commits and 19 migrations behind staging:
  - least-privilege roles: `operator_gateway`, `barcode_service`, `stream_engine`, `legacy_replicator`;
  - `t-rls-helpers-parallel-safe`;
  - Timescale Phase A: A1 drops `ca_equipment_boxes_1s`, A5 turns on job logging;
  - sandbox heal ×3;
  - invariants v9–v13;
  - `t-readapi-screen-config`, `t-cpac-shadow-dup-indexes`, `t-daily-time-raw-comments`, `t-plc-link-minutes-retention`;
  - the edge-api pin `c5061d53` → `282e26a9` (setup lock_timeout, idempotency v2, audit, #311).
- **#1782 (OPEN, CI green):** production compose moves stream-engine, legacy-replicator and operator-gateway to their own
  logins (`packiot/production/<svc>-db-creds`), and the CI guard now covers `compose.production.yml`. barcode-service is
  not in the production compose (release 2).
- **#1784 (OPEN, CI green):** the transplant fixes in §4.

## 2. The clone

| Item | Value |
|---|---|
| Source | AWS Backup AMI of `packiot-production-db` taken 2026-10-14 04:12 UTC (existing; no new snapshot) |
| Instance | `r7g.large` (16 GB, the prod DB size) in the prod DB subnet. Security group with **no ingress**, egress 443 only (SSM). SSM-only role |
| Postgres | `rehearsal-pg`: same image (`timescale 2.25.2-pg16`) and same pgdata, no published port |
| Inputs | Staging `pg_dump --schema-only` (1 s, read only) and `catalog.sql` on staging and on the clone. `cpack-config-sync.py extract` read-only on staging (62 equipments, 570 reasons, 2,258 links) |
| Lifetime | 22:50 → 00:17 UTC (1 h 27 min ≈ $0.17). Instance terminated, volume deleted with it, SG deleted, S3 `promotion-rehearsal/20261014/` removed |

## 3. Timings (run 3 = the fixed tooling on a warm volume)

| Step | Time | Result |
|---|---|---|
| `roles` (server-level) | 0.1 s | 6 roles, LOGIN without a password, settings = staging's. Re-run = no change (run 3 was the 3rd application) |
| `joblog` (server-level) | 1.1 s | `timescaledb.enable_job_execution_logging = on` |
| `create` `pre` `hyper` `views` | 5.2 s | `pre` has 222 expected errors: grants on caggs that don't exist yet, re-applied in `grants` |
| `copy` | **115.7 s** | 67 tables. A cold volume freshly restored from a snapshot took 300 s (run 1); the prod volume is warm |
| `repair` `post` `checks` `data` | 4.9 s | 0 inconsistent shifts, 0 overlaps. `equipment_events` has **58 chunks** (was 1,555) |
| `cpack-diff` → `cpack` | 2.0 s | 62 equipments updated, 570 reasons, 2,258 links, identity ok 62 |
| `logic` `grants` `policies` `hasura` | 4.9 s | **0 errors**. Guard `raw retention policies (want 0)` = 0 |
| **Transplant total** | **2 min 14 s** | |
| Swap (terminate + 2 renames) | **11 ms of SQL** | Background workers restarted |
| Deploy-shaped start | ~40 s | One-shots `db-init-bootstrap`, `db-schema-f3` (skips: F3 present), `db-knex-baseline` and `db-migrate` (1 knex migration, `20261008000001_po_number_text_key`, a no-op behind its trigger guard). Then edge-api, stream-engine and read-api healthy |
| `refresh` (after the swap, services live) | 415 s | 0 errors; 47,796 resolved downtime rows |
| `ops.job_data_invariants` | 190 s (staging: 27–70 s) | Completes, no OOM. Failures in §5 |
| **Rollback** (stop services, terminate, rename back, restart pgbouncer) | **124 ms of SQL, 1.3 s total** | Read back: the old layout (`public.production_orders` = 19,789) is served, also through pgbouncer |

## 4. Findings (all fixed in #1784 unless noted)

1. **Second OOM trap: a crash loop, caused by the chunk count rather than the data size.**
   - Prod's `silver.equipment_events` holds daily events since 2021. Staging's 1-day interval turned that into
     **1,555 compressed chunks** (staging has 156).
   - stream-engine's hour exclusions query (`rollup/availability_exclusions.go`, correlated subqueries bounded by per-row
     ranges) grew one backend to **7.7 GB**. The kernel **OOM-killed Postgres 10 times in 18 minutes**, and engine ticks
     timed out at 300 s.
   - **On prod this starts minutes after the go-live.**
   - Fix: the history is created with 30-day chunks (58), and new chunks go back to 1 day.
   - Re-run: 25 minutes with 0 OOMs, backends ≈ 0.7 GB, 0 engine errors or timeouts.
   - The first invariants crash at 23:28 happened in the same storm; invariants alone complete in 190 s.
2. **Every continuous aggregate had no grants.**
   - Cause: `build.py` skipped the caggs' TOC entries, and their ACLs went with them.
   - Effect: read-api as `readapi_ro` would have got `permission denied` on `silver.agg_*` / `equipment_*_1min`.
   - The 10-08 catalog check could not see it, because it does not compare ACLs.
   - Fix: re-apply the grants, plus a new `compare-acl.py` (ACLs, policies, RLS, role settings, jobs, retention).
     Before the fix it reports the 6 caggs; after it reports **0**.
3. **No roles.** A schema dump carries GRANTs, not roles or `ALTER ROLE … SET`, and prod lacked all 6 service roles. The new
   `roles` phase is server-level and touches the live server before the swap. It is additive and inert for the old DB.
4. **`apply_retention()` aborted on `silver.ca_equipment_boxes_1s`.** A1 drops that relation, but `t-retention-catalog`
   still seeds its catalog row. The abort left the hot_agg/business retention unapplied. Fix: delete catalog rows for
   relations that no longer exist before the call.
5. **`xplant.sh` could not run on prod as written.** The container is `timescaledb` (`PGC`), and the post-swap `refresh`
   targets `packiot` (`XPLANT_DB`).
6. **`docker exec` without `-i` silently drops a heredoc.** The first rollback attempt printed success and renamed nothing.
   The runbook now requires reading the rename back.
7. **Least-privilege provisioning on prod needs an IAM write grant.** The prod app role can only read secrets. #1784 authors
   `WriteProductionDbRoleSecrets` (`packiot/production/*-db-creds*`), **not applied**.
8. **Checked and fine:**
   - prod's `pg_hba.conf` accepts every role (`host all all all scram-sha-256`);
   - `t-plc-link-minutes-retention` is now in the data phase;
   - the knex `po_number_text_key` re-run is a guarded no-op.

## 5. Verification evidence (run 3)

- **Catalog vs staging:**
  - tables 84/84, indexes 192/192, constraints 176/176, sequences, caggs 6/6 (equal after PG15→16 normalisation),
    functions 113/113 (body md5), types, policies 11/11, triggers 14/14 → **0 missing / 0 different**;
  - extras = `hdb_catalog` (the hasura phase);
  - views differ only by PG15→16 column qualification.
- **ACL / RLS / policies / role settings:** 0 differences.
- **Jobs:** staging's 27 minus raw retention (`PROD_RAW_RETENTION=off`) and `purge_analytics_plain`. Retention present:
  events 5 y, 1-hour caggs 13 months.
- **Data vs the old DB:** 62/67 tables equal. The 5 by-design differences are `production_targets`, `translations` and
  `client_descriptors` (phase D), and `downtime_reason` / `equipment_downtime_reason` (the CPACK sync).
  - **ADR-0062:** 19,789 POs; 0 without a number or `po_uuid`; 0 duplicates; D5 `1585550 → 889583`.
  - **ADR-0061:** 64 active bindings for 64 equipments.
- **Least-privilege logins:**
  - `stream_engine` logs in with `app.tenant_id=-1` and ran the engine (15 sessions on staging; on the clone 2 + 7 pool
    sessions);
  - `legacy_replicator` logs in, `operator_gateway` logs in read-only with 5 s, and `readapi_ro` serves read-api;
  - `verify.sql` passes for operator-gateway and stream-engine;
  - legacy-replicator's V10d calls the staging-only sandbox function (twin only; the prod instance has
    `SANDBOX_HOLD_ENABLED=false`);
  - barcode's verify collided with the smoke test's own label 1 (a clone artefact; barcode is not in prod scope).
- **Smoke, over HTTP inside the stack network, on a rehearsal tenant created on the clone:**
  - **edge-api:** PO create ×2 with one `Idempotency-Key` gives 1 PO, 1 key and the replayed body; then start (runtime
    opened), box scan 201, current 200, stop(pause) 201; audit rows 5;
  - **read-api:** healthz 200, catalog 200, `/v1/query` `1min` 200 and `1hour` 200 (cagg reads as `readapi_ro`);
  - **edge-api, stream-engine and read-api:** 0 errors and 0 `permission denied`.
- **Engine:**
  - gold rows computed after the swap: 42 hourly, 81 shift, 42 daily, 102 site-shift;
  - 0 errors, 0 tick timeouts after the fix.
  - Open observation: a re-flagged CPACK hour (62 rows): 20 flags were cleared as stranded, and 42 are "drained" every
    minute without the flag clearing; values unchanged. This is the known stranded-flag class
    (`feedback_stranded_flags_never_drain`), so it is a follow-up, not a blocker.
- **Invariants on the clone:**
  - **Clone artefacts:** C1 freshness (no live feed on the clone); C3 cagg vs raw 24 h (measured before the refresh).
  - **Prod data, for the §6.7 reviews:** C6 shift gross vs lead (11 lines), K4 hourly bounds (41), R2 routing (6),
    S2 stale open stops (13), V1 one saturated counter.

## 6. Go / no-go checklist and the user's remaining actions

| # | Item | Status |
|---|---|---|
| 1 | Merge #1784 (transplant fixes) and #1782 (prod least-privilege compose) into the release branch. Merging deploys nothing | **USER**: CI green; my session was not allowed to merge |
| 2 | Terraform apply `production`: B1 RabbitMQ creds + internal keys, `databaseCredentials` read, #1144 Cognito pool, **new `WriteProductionDbRoleSecrets`** | USER |
| 3 | B3: prod runner token able to fetch `csadmin` | USER |
| 4 | `/opt/packiot/.env` on the prod app box: `READAPI_RO_PASSWORD`, `INTERNAL_API_KEY`, `LEGACY_DB_PASSWORD`, `REFDATA_QUERY_API_KEYS`, `ONBOARD_API_KEY` | USER |
| 5 | Before the window: `PGC=timescaledb xplant.sh roles joblog` on the prod DB host (server-level, additive) | at go-live |
| 6 | Window: drain RabbitMQ (§5a) → stop writers → transplant (≈2.3 min) → verify (`compare-catalog.py` + `compare-acl.py`, both 0) → swap → restart pgbouncer | at go-live |
| 7 | Least-privilege provisioning on the prod **app** host, after step 5 and before starting the services: `scripts/ops/provision-db-role.py --service {stream-engine,legacy-replicator,operator-gateway} --env production --db-host <POSTGRES_HOST_UPSTREAM> --admin-host <POSTGRES_HOST_UPSTREAM> --db-name <POSTGRES_DB>` | at go-live (rehearsed by setting role passwords from host-generated values on the clone; **no secrets were created**) |
| 8 | Merge release → `production` (the deploy trigger), then smoke as in §5. Then `XPLANT_DB=packiot xplant.sh refresh`, §5b legacy-replicator backfill, and the §6.7 reviews | USER: the go |
| 9 | Hasura metadata (§6.6) | USER |
| 10 | Snapshot the prod DB volume right before the window (runbook §5 step 0) | at go-live |

**Not rehearsed here:**
- the RabbitMQ drain (§5a; the clone has no old-gen workers);
- Hasura and csadmin/operator containers;
- legacy-replicator against the legacy DB (no legacy access by design);
- Secrets Manager writes (no prod IAM).

## 7. Open risks and housekeeping

- **Four orphaned 100 GB gp3 volumes from the 10-08 rehearsal** are still `available`: `vol-00d1a05d693a25335`,
  `vol-011ec0d5ad3405b4a`, `vol-00159bade24e6f3f7`, `vol-08329831466054fee`. All are tagged
  `Purpose=promotion-rehearsal-throwaway` and come from `snap-01587ba5ab3dd384e`. They cost about $32/month and contain
  **prod data copies**. Recommend deleting them (needs the user's OK).
- Invariants take 190 s on the prod shape (staging: 27–70 s), every 30 min. Watch the first runs.
- Right after `policies`, the compression policy compresses the whole copied history at once (≈76 s for events on the
  clone). That is extra load in the first minutes, but it is bounded.
- Cold-volume risk does not apply to prod (its volume is warm). A fresh clone needs about 2.5× the copy time.
- The engine's deploy-restart catch-up tick stayed within its 300 s budget once the chunk fix was in. Before the fix it
  timed out because of the crash loop.
