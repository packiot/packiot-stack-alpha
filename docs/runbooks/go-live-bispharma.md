# Go-live runbook — Bispharma (enterprise 5) on the new production stack

**Status:** rehearsed end to end on throwaway clones on 2026-10-15
([report](go-live-bispharma-rehearsal-2026-10-15.md), on `staging`). **Nothing has run on production.** The go is the
user's: merging `release/prod-promotion-2026-10` into `production` deploys.

**2026-10-16 — adapted to TimescaleDB-free staging** (ADR-0063 end state, ADR-0065): the new prod database is born
**without TimescaleDB** (native partitions, the rollup tick, housekeeping from host timers). The rehearsal above ran on the
TimescaleDB shape; the TS-free path is proven by `selftest-clean-server.sh` (§2.2) and needs one more clone rehearsal
before the go. Changes are marked **(TS-free)** below.

**Scope (user decisions, 2026-10-15):**
- Production goes live for **Bispharma only**.
- Production starts **clean**: staging's schema, plus Bispharma's config and history copied from staging (enterprise 5).
  Nothing is transplanted from CPACK or legacy. CPACK stays on legacy until its own go-live.
- The production box is **installed in the go-live window**, on Bispharma's real VM, **next to the existing staging box**.
- The PLC is read by **two independent readers** (staging and production).
- Staging stays Bispharma's live system until the go, and remains the **rollback**.

This runbook reuses the transplant tooling (`scripts/promotion/transplant/`, runbook
[production-promotion-transplant-runbook.md](../adr/reference/production-promotion-transplant-runbook.md)). It replaces
the `copy` phase with a single-tenant load (`scripts/promotion/bispharma/`).

---

## 1. Decisions and why

| # | Decision | Why |
|---|---|---|
| D1 | **Same prod DB server, new database.** Build `packiot_next` next to the old `packiot`, then swap the names. The old DB is kept as `packiot_pre_promotion` | The server also holds Superset's metadata DB (`superset`), the `authentik` DB, and the server-level roles with their passwords (`superset_ro`, `superset`, `hist_gw_ro`). A new data directory would have to carry all of them. The old DB is CPACK's prod history, needed later for CPACK's own go-live; it is never modified |
| D2 | **Image `timescale/timescaledb:2.27.0-pg16@sha256:51eb3bcd…`** with `shared_preload_libraries=timescaledb,pg_stat_statements,auto_explain` and `max_connections=200` (`terraform/production/database.tf`) | It is staging's TimescaleDB (2.27.0), so every behaviour proven on staging holds (ADR-0063 §7 step 1). It stays on PostgreSQL 16, so prod never needs a major upgrade. The image still ships the 2.25.2 libraries, so the old DB keeps working unchanged. Rehearsed on a prod-AMI clone: restart 5 s; all 5 databases open; the old DB's queries, caggs and 14/14 jobs run under the new image. Today the prod server runs with `max_connections=100` and no `pg_stat_statements`; the flags match staging's `db_init.sh` minus `pg_cron`, which the F3 schema does not use |
| D3 | `packiot_next` is created **from `template0`** | The prod server's `template1` carries TimescaleDB 2.25.2. A plain `CREATE DATABASE` inherited 2.25.2 even under the 2.27.0 image (rehearsal finding) |
| D4 | **Ids are preserved.** Every enterprise, site, area, equipment, topic route, device key and api key keeps its staging value | The factory box, the reader config and the descriptor all reference them. The generator renders the box's bundle byte-identically from the copied descriptor (§5.1) |
| D5 | **Sequences are floored above the old DB's ids** (`seq-floor.sql`) | Bispharma has no POs yet, so `core.production_orders` would restart at 1 while CPACK's prod history goes up to ~1.68 M. CPACK's later go-live into this DB then keeps its ids. 9 sequences are raised (POs → 1,676,663). **Then every sequence is floored at 1,000,000,000** (the production id block, [ADR-0064](../adr/0064-staging-mirror-of-production-after-go-live.md) D6, on `staging`): staging mirrors production after the go-live and copies production's rows with their ids, so production's ids must never fall in staging's range (staging's highest: 601,633,961). It also removes the collision class of the old-DB floor (legacy CPACK keeps minting after that snapshot) |
| D6 | **Group id stays `BISPHARMASTAGING`** in prod | Topic routes, ADR-0061 device keys, the descriptor's `tenant` and the reader's metric suffixes are all keyed on it. Renaming is its own change, with its own rehearsal |
| D8 | **(TS-free)** The new database has **no TimescaleDB**. The server keeps the D2 image (the library stays loaded for `packiot_pre_promotion` and for rollback); the database never runs `CREATE EXTENSION timescaledb` (`01-extensions.sql` is empty for a TS-free staging, `db-init-bootstrap` no longer creates it) | Staging dropped it on 2026-10-15 (ADR-0063); production must run what staging proved. Removing the library from the server is a later step (§8 item 11) |
| D9 | **(TS-free)** Housekeeping runs from **systemd timers on the DB host** (`scripts/ops/analytics-housekeeping.sh`, `systemd/analytics-housekeeping@*.timer`): partition-maintain 03:20, downtime-resolved every 2 min, data-invariants every 30 min. No `purge_analytics_plain` | The D2 image has no pg_cron (staging's scheduler) and the TimescaleDB job scheduler is gone with the extension. Same statements as staging's pg_cron jobs (`scripts/ops/adr0063-c2-pgcron-jobs.sql`) |
| D10 | **(TS-free)** stream-engine's rollup tick is **on by default in prod** (`ROLLUP_SHADOW_ENABLED` defaults to `true` in `compose.production.yml`) | It is the only minute/hour rollup since ADR-0063 B2. Found 2026-10-16: prod's compose did not pass the variable at all, so prod would have computed no minute/hour/gold after the go-live |
| D7 | **Raw values are not carried** (`bronze.equipment_values_raw`). Silver, gold, serving, events, box scans, samples, POs, shifts, targets, reasons and descriptors are | Bronze raw is staging's 90-day replay buffer; silver is the system of record. Prod raw starts at the go-live and is kept forever (`PROD_RAW_RETENTION=off`) |

## 2. Database migration

### 2.1 What travels (`scripts/promotion/bispharma/tenant_extract.py`, catalog-driven)

The generator reads staging's catalog. It stops if a table has no rule, so a table added to staging later must be
decided, not silently copied or dropped.
**(TS-free, 2026-10-16, on staging's real catalog):** 74 tenant tables, 8 global (+ `ops.pc_state`, the partition
registry `partition_maintain` iterates), 1 catalog (`ops.retention_policy`: staging's, copied and **not** fingerprinted —
phase `data` sets every `hot_raw` keep to forever), 10 skipped (+ `ops.cold_export`, staging's cold-tier manifest that
points at staging's bucket; `ops.partition_drop_blocked`). Partitions travel through their parent (131 on staging; a
partition is never a table of its own in the plan). The former caggs (`silver.equipment_categorical_1min/1hour`,
`silver.agg_equipment_values_1min/1hour`) are plain tables now and **travel with the tenant** (before: rebuilt by phase
`refresh`). `*__old` tables (ADR-0065 P3a rollback copy) are staging-only. The counts below are the 2026-10-15 rehearsal's.
- **69 tables, filtered to enterprise 5:**
  - by `id_enterprise` (or `customer_id`);
  - or through `core.equipments`, `core.areas`, `core.sites` or `core.production_orders`.
- **Platform tables also carry the platform-admin enterprise 1000000:** `core.enterprises`, `identity.users` and
  `identity.user_roles` (1 enterprise row, 1 role, 1 user).
- **7 global tables:** translations, language packs, pages, `machine_state`, the knex ledger (so `db-knex-baseline` and
  `db-migrate` see every migration as applied), and the serving coverage marker.
- **8 skipped tables, each with a reason:**
  - bronze raw;
  - the idempotency cache;
  - CPACK replicator tables;
  - retention tables, which are seeded by phase `data`;
  - staging's invariant run history.
- **Users:** staging and prod share one Cognito pool (`us-east-1_0T9t1sTwt`), so Bispharma's 2 users keep their
  `id_user_cognito` and can log in to prod unchanged.

**Volume (2026-10-15):**
- 9,316,727 rows in 2.3 GB of COPY text;
- `silver.equipment_values` alone is 8,584,280 rows (since 2026-09-02), and `silver.plc_link_minutes` is 440,889;
- `core.production_orders`, box scans and samples have **0** rows on staging today.

### 2.2 Phases on the prod DB host (container `timescaledb`)

```
TRANSPLANT_MODE=tenant python3 scripts/promotion/transplant/build.py <workdir>     # needs cat-stg.json, cat-prod.json, stg-schema.dump
python3 scripts/promotion/bispharma/tenant_extract.py <workdir>                     # writes out/04t-tenant-load.sql, 12t-tenant-verify.sql, seq-floor.sql
PGC=timescaledb TENANT_DIR=/root/tenant5 xplant.sh roles joblog create pre hyper views tload repair post checks data logic grants tverify policies seqfloor
```
- Before the window, on any machine with docker: `scripts/promotion/transplant/selftest-clean-server.sh` (~1 min, local
  throwaway containers). It builds a mini staging with the real `t-enterprise-codes` + `t-prod-reflector-roles`
  migrations, runs the phases above on a clean server and checks the catalog/ACL/tenant gates. `roles` creates
  `prod_reflector_ro` (the production login) and `prod_reflector` (staging's login; on prod passwordless and unused — step 8a
  applies the same migration anyway).
- **(TS-free)** `hyper` generates nothing (no hypertables/caggs) and `joblog` is a no-op; both stay in the list so the
  same command line works for either shape. `policies` runs `10-housekeeping.sql`: `ops.partition_maintain()` once
  (partitions 60 days ahead), the downtime refresh and the invariants once, then four guards that must print 0 (no
  timescaledb in the database, no raw retention, no raw partitioned relation with a keep, every partitioned relation has a
  partition more than 30 days ahead). The selftest's fixture is staging's TS-free shape (real `t-ts-c3`, `t-ts-c4`,
  `t-adr0065-p0` migrations; partitions with both catch-alls; a former cagg + its view; a `__old` table) and also fails
  on any `ERROR` in any phase.
- `TRANSPLANT_MODE=tenant` restricts phase `data` to the retention catalog. **(TS-free)** it no longer runs
  `t-retention-catalog` (that re-seed would write the pre-ADR-0063 kinds back); it prunes the copied catalog and applies
  `PROD_RAW_RETENTION=off`.
  - The rehearsal's fingerprint diff caught the business backfills **rewriting Bispharma's curated config**:
    `t-ideal-speed-best-demonstrated` re-derived machine M682's `production_speed` from 110 to 241, and through it its
    line's targets.
  - The t244 descriptor inserts would also have added other tenants' rows.
- `tverify` runs **before** `policies`. Once the jobs are registered, `serving.downtime_events_resolved` is rebuilt by
  its job, so its content no longer matches the snapshot (the row count still does).
- `cpack-diff`, `cpack` and `hasura` are **not** run. Hasura starts with fresh metadata; its old metadata tracks
  CPACK-era tables.

### 2.3 Integrity gates (all must pass; rehearsed)

| Gate | How | Rehearsal |
|---|---|---|
| Rows and content equal to the staging snapshot | `fingerprint-diff.py extract.out 12t-tenant-verify.sql.out`: count plus md5 of the ordered rows for every config table; for hypertables / **(TS-free)** partitioned tables and the four former caggs, count, first/last day and md5 of the per-day counts | 76/76 equal, 9,316,727 rows |
| No other tenant's rows anywhere | `purity` lines in the same output: 50 tables with a tenant key, 0 foreign rows | 0 |
| Referential integrity | phase `post` adds every FK after the load; an orphan is an `ERROR` | 0 errors |
| CHECK invariants | phase `checks`: 32 CHECKs re-added `NOT VALID`, then `VALIDATE` | 0 errors |
| Schema = staging | `compare-catalog.py cat-stg.json cat-next.json` | 0 missing/different (views: PG15→16 normalisation) |
| Grants, RLS, policies, role settings, jobs = staging | `compare-acl.py acl-stg.json acl-next.json` | 0. Jobs = staging's 27 minus 8 raw-retention policies and `purge_analytics_plain` (by design). **(TS-free)** jobs and compression are empty on both sides (housekeeping lives outside the database, D9) |
| **(TS-free)** Housekeeping guards | `grep 'want 0' out/10-policies.sql.out` | 4 × 0 (selftest) |

## 3. What prod runs for one tenant (`compose.production.yml`, this PR)

| Service | Bispharma-relevant change |
|---|---|
| `sparkplug-agent-shared` (**new on prod**) | The thin-reader front door (box → `https://ingest.prod.packiot.app:8449/v1/tags` → nginx TLS → agent `:9104` → mosquitto). It mounts **only** `docs/clients/tenants/bispharma.yaml` and its profile, and fails closed without `AGENT_INGEST_API_KEY` |
| `stream-engine` | `COUNTERS_ONLY_LINE_LEAD_ENTERPRISES "3,5"`, `CPAC_EVENT_LIVE_ENTERPRISES` default `5` (Bispharma's stops are minted live by the second CPAC deriver), `EVENTS_CLOSE_STALE_ENTERPRISES "3,5"`. These are staging's values for ent 5 |
| `sparkplug-decoder` | `POSTGRES_HOST: ${POSTGRES_HOST_UPSTREAM}`. **Prod defect found by the rehearsal:** through pgbouncer, every periodic DB reload failed with `prepared statement "stmtcache_…" does not exist`, so the counters-only rates and OEE margins **never loaded** (an empty snapshot from boot). Direct, as on staging, it loads 112 rate entries. Profile `client-ingest` must be in `COMPOSE_PROFILES` |
| `edge-api`, `read-api`, `operator`, `csadmin` | Unchanged. `operator` serves Bispharma via `OPERATOR_EDGE_API_KEY` / `OPERATOR_REFDATA_API_KEY` |

Terraform `production` (not applied):
- the app SG admits `8449` from `var.shared_ingest_egress_cidrs = ["200.153.25.2/32"]`;
- `nginx_setup.sh` gets the `ingest.<domain>:8449` vhost, identical to staging's;
- `database.tf` pins D2.

## 4. DNS and hosts

All records already exist in `prod.packiot.app`, read 2026-10-15:

| Who | Host | Path |
|---|---|---|
| Bispharma's box (production reader) | `ingest.prod.packiot.app:8449` | A → app EIP 3.232.9.118, **direct** (not CloudFront); SG /32; TLS = the wildcard LE cert |
| Bispharma users (dashboards) | `front.prod.packiot.app` | CloudFront → front4; API calls to `api.prod` / `refdata.prod` |
| Shop floor (operator) | `operator.prod.packiot.app` | CloudFront → nginx → `operator` (Cognito, any pool user) |
| Reports | `bi.prod.packiot.app` | CloudFront → prod Superset (its metadata DB `superset` stays on the DB server, D1) |
| CS | `csadmin.prod.packiot.app`, `api.prod.packiot.app` | as today |

The box needs outbound `443` (pip, Docker Hub: as today) and `8449` to 3.232.9.118.

## 5. The box: production instance next to staging

### 5.1 PLC second reader: proceed

- **The PLCs:** Siemens S7, rack 0 / slot 2 / port 102 (the S7-300 family), 23 endpoints / 91 DINT tags.
- **Reader load today:** python-snap7 opens a fresh PG-type connection per PLC per cycle. It does 2–5 four-byte
  `db_read` calls, then disconnects: about 10 ms per PLC on 192.168.5.x and about 200 ms on 192.168.7.x.
  - The configured poll is 5 s (read on the box); the effective cycle is about 12 s (`silver.plc_link_minutes`:
    4.98 ticks/min).
  - That is about 0.4 PDU/s per PLC.
- **With a second reader:** about 0.8 PDU/s per PLC, and at most 2 simultaneous connections, only in the rare
  ≤ 10–200 ms overlaps.
- **Siemens connection resources:** a CPU 315-2 PN/DP has 16; even the smallest S7-300 has ≥ 12. The only tight case
  is a CP 343-1 Lean (4 S7 connections) shared with an HMI and the legacy Pi.
- **Keep:** poll interval ≥ 5 s and the default PG connection type.

**Pre-go check on site (CS):** in TIA/Step 7 (*Online & diagnostics → Connection resources*), on one SP PLC and one
BISNAGO PLC:
- free connections ≥ 2 while the staging reader, the HMIs and the legacy Pi run;
- no "connection rejected" entries in the diagnostic buffer;
- note the CPU order number;
- confirm whether the legacy Raspberry Pi is still polling.

**Fallback if a PLC has no free resource:** one reader posting to both clouds. The reader already fans out to several
`targets`, so this needs zero extra PLC connections, at the cost of independence.

### 5.2 Coexistence (rehearsed with both instances on one Docker host)

edge-api's generator renders one instance per box. Its container names, its helper port 1880 and (for this on-prem
tenant) its local tee to `127.0.0.1:9104` would collide with, or feed into, the staging instance. Prod edge-api has no
SSM box access (B6), so the production instance is rendered and installed by hand.

`scripts/promotion/bispharma/render-box-instance.mts` calls the generator **unchanged**. Rendered from prod's copied
descriptor, the staging bundle comes out **byte-identical** to the box's `compose.edge.yml`, `reader.py` and
`reader.config.json` (sha256 compared on the box, read-only). It then applies one asserted overlay:

| | staging (today, untouched) | production |
|---|---|---|
| Directory / compose project | `/opt/packiot` / `packiot` (+ `/opt/packiot/fatedge` / `fatedge`) | `/opt/packiot-prod` / `packiot-prod` |
| Containers | `packiot-edge-reader`, `packiot-nodered-helper`, `onprem-*` | `packiot-edge-reader-prod`, `packiot-nodered-helper-prod` |
| Ports | helper `127.0.0.1:1880`, agent `127.0.0.1:9104`, dashboard `0.0.0.0:1881` | helper `127.0.0.1:1890`; none other (the reader uses host networking, no listener) |
| Volumes / spool | `packiot_nodered-data`, `/opt/packiot/spool` | `packiot-prod_nodered-data`, `/opt/packiot-prod/spool` |
| Reader targets | cloud `ingest.staging:8449`, local `127.0.0.1:9104`, helper `:1880` | cloud `ingest.prod:8449`, helper `:1890`. **No fat-edge tee:** the staging instance keeps the outage dashboard |
| Env | `/opt/packiot/.env` | `/opt/packiot-prod/.env` (mode 600, `INGEST_KEY` from a root-only file, never echoed) |
| Resources | reader ≈ 20 MiB / 5 % CPU, helper ≈ 54 MiB (box: 4 vCPU, 15.4 GiB, 8.9 GB disk free) | the same again; no limits needed |

Install, by the user over SSM on `mi-0114b66366e2d6613`, in the window:
1. Put the prod ingest key in `/root/.packiot-prod-ingest-key` (root-only, one line).
2. Run `install-prod.sh` (14.5 KB, one RunShellScript).
3. The script prints the prod containers and confirms the staging ones are untouched.

Rollback: `uninstall-prod.sh` (it stops only `packiot-prod`). Rehearsed: the install takes 0.6 s, and the first reader
cycle comes 19 s later (pip install of snap7).

## 5.3 Staging becomes a read-only mirror of production (ADR-0064)

From the window on, **production is Bispharma's single source of truth**. Staging keeps its own box instance and reader
(the rollback base), but enterprise 5 on staging becomes a **read-only mirror** (ADR-0064 and
`docs/runbooks/staging-mirror-of-production.md`, both on `staging`):
- **one switch** `PROD_MIRROR_ENTERPRISES=5` in staging's `/opt/packiot/.env` (edge-api, barcode-service, stream-engine,
  prod-reflector);
- every write of enterprise 5 on staging → 403 "read-only mirror of production — make this change in production";
  the SPAs show a banner;
- **prod-reflector** copies everything production owns (config, users, POs, events + justifications, scans, samples,
  OEE) into staging every minute, production wins; staging's engine skips enterprise 5;
- staging's enterprise name becomes **"Bispharma (mirror)"**; keys stay per environment;
- invariants MR1–MR5 (`ops.data_invariant_result`, source `prod-reflector`) and ProdMirror* alerts.

Network: a VPC peering staging ↔ production, a route to the production DB `/32`, one DB SG ingress from the staging app
(`terraform/production/mirror_peering.tf`, `staging_mirror_enabled`; `terraform/staging` `prod_mirror_peering_id`).
Plans (2026-10-15, targeted, no lock): production **+1 peering, route table +1 route, DB SG +1 ingress** (the app SG
8449 change in the same plan is §3's); with the var off, no change of its own. Staging: IAM policy +1 secret ARN; with a
peering id, +1 route.

## 6. Cutover sequence

**T-1 day (no customer impact):**
1. Merge this PR and catch the release branch up with staging (it is 14 commits behind: the stream-engine statement fixes
   #1785/#1786). Merging into the release branch deploys nothing.
2. Terraform apply `production`:
   - the 10-14 items (B1 creds, `WriteProductionDbRoleSecrets`, the #1144 pool, `databaseCredentials` read);
   - the `8449` SG rule;
   - `nginx_setup.sh` upload. Then re-run `nginx_setup.sh` on the app box (`nginx -t` gate).
3. On the prod app box, in `/opt/packiot/.env` (values never echoed):
   - `AGENT_INGEST_API_KEY` (the prod ingest key, also given to the box in step 10);
   - `OPERATOR_EDGE_API_KEY` = ent 5's `enterprises.api_key` (after step 9);
   - `REFDATA_QUERY_API_KEYS` with an entry `<key>:5`, and `OPERATOR_REFDATA_API_KEY`;
   - `COMPOSE_PROFILES` containing `client-ingest`.
4. CS on site: the PLC connection-resource check (§5.1).
5. Snapshot the prod DB volume.
6. **Staging mirror prerequisites (§5.3):**
   - packiot-stack `staging` (prod-reflector) and edge-api `staging` (the write block) deployed — inert while the switch is unset;
   - on staging: `db/migrations/t-prod-reflector-roles` applied + `verify.sql`; `provision-db-role.py --service prod-reflector`;
   - terraform `production` apply `-var staging_mirror_enabled=true`, then `terraform/staging` apply
     `-var prod_mirror_peering_id=<output staging_mirror_peering_id>`;
   - from the staging app host: `pg_isready -h 10.20.10.89` → accepting connections.

**T-0, the window.** Bispharma keeps running on staging throughout; nobody is down.

| Step | What | Rehearsed time |
|---|---|---|
| 1 | Stop the prod app services (`docker compose -f compose.production.yml stop`; prod serves no customer today) | — |
| 2 | **Image swap** on the DB host: `docker rename timescaledb timescaledb-2252`; `docker run` D2 on the **same** `/opt/packiot/pgdata` with name `timescaledb` (the `database.tf` command). Keep the old container stopped, for rollback | 5 s to ready |
| 2a | **Staging write block ON** (before the extract, so the snapshot is final): `PROD_MIRROR_ENTERPRISES=5` in staging's `/opt/packiot/.env`; recreate `edge-api barcode-service stream-engine` (`-p stack`). Check: an ent-5 PO create → 403 `MIRROR_TENANT_WRITE_BLOCKED`; ent 3 unaffected. From here staging's ent-5 OEE is frozen until step 11c | — |
| 3 | **Staging extract** (READ ONLY, one REPEATABLE READ snapshot), streamed to S3 `promotion-rehearsal/<date>/` (a go-live prefix of the same bucket), then to the DB host | 55 s extract + 56 s upload + 10 s download |
| 4 | `xplant.sh roles … seqfloor` (§2.2) | 155 s on r7g.large (of which `tload` 109 s, `seqfloor` 28 s) |
| 5 | Gates (§2.3): fingerprint and purity diff, compare-catalog, compare-acl | ~1 min |
| 6 | **Swap**: terminate connections; `packiot → packiot_pre_promotion`; `packiot_next → packiot`; `start_background_workers()` **in `packiot_pre_promotion` only** (TS-free: the new `packiot` has no timescaledb, the call would fail there); read back `current_database()` and the extension versions (`packiot`: no timescaledb) | 68 ms SQL |
| 7 | `XPLANT_DB=packiot xplant.sh refresh` in the background. **(TS-free)** only `serving.downtime_events_resolved` is rebuilt (no caggs; the rollup tables travelled) — seconds, not minutes. Shred `/root/tenant5` | 438–563 s (TS shape) |
| 7a | **(TS-free) Housekeeping timers** on the DB host: copy `scripts/ops/analytics-housekeeping.sh`, `scripts/ops/install-analytics-housekeeping.sh` and `systemd/analytics-housekeeping@*` keeping the repo layout (with the xplant bundle), then `sudo bash scripts/ops/install-analytics-housekeeping.sh` → 3 timers listed. Check: `systemctl start analytics-housekeeping@partition-maintain` → exit 0 | — |
| 8 | `provision-db-role.py --env production --db-name packiot --db-host 10.20.10.89 --admin-host 10.20.10.89` on the prod app host for stream-engine, legacy-replicator and operator-gateway (10-14 item 7), **and `--service readapi-ro`**. The transplant creates `readapi_ro` LOGIN *without* a password; this applies terraform's `internal-keys.readapi_ro_password` (= `READAPI_RO_PASSWORD` in `.env`) and logs in with it. Without it read-api, and so every dashboard, fails auth after step 10 (found 2026-10-15; the rehearsal set it in a clone-only script). `superset_ro` needs nothing: it is server-level and already has its password | — |
| 8a | Check the id block: on `packiot`, `SELECT min(last_value) FROM pg_sequences WHERE last_value IS NOT NULL AND sequencename NOT LIKE 'knex%' AND schemaname NOT LIKE '\_timescaledb%'` ≥ 1000000000. Apply `db/migrations/t-prod-reflector-roles/01-up.sql` + `verify.sql` to `packiot` (idempotent), then `provision-db-role.py --service prod-reflector-ro --env production --db-name packiot --db-host 10.20.10.89 --admin-host 10.20.10.89` (secret `packiot/production/prod-reflector-ro-db-creds`) | — |
| 9 | Optional, recommended: **rotate ent 5's api key on prod** (`UPDATE core.enterprises SET api_key = gen_random_uuid()::text WHERE id_enterprise = 5`, on the host), so staging's key is not valid on prod. Put it in `OPERATOR_EDGE_API_KEY` | — |
| 10 | Merge release → `production`: the deploy runs the one-shots, then the services | one-shots 2 + 1 + 3 + 17 s; services healthy in 10 s |
| 9a | Rename ent 5 on prod: `UPDATE core.enterprises SET nm_enterprise = 'Bispharma' WHERE id_enterprise = 5` (staging then shows "Bispharma (mirror)") | — |
| 11 | Smoke: edge-api PO create ×2 with one `Idempotency-Key` gives 1 PO; start; box scan; current; read-api `/v1/catalog` and `/v1/query` 1min/1hour with the ent-5 read key | all 200/201 |
| 12 | **Box install** (§5.2) | 0.6 s; first post at 19 s |
| 11a | **Reflector dry run** on the staging app host (3 min, writes nothing): `timeout 180 docker compose -f compose.staging.yml -p stack run --rm -e PROD_REFLECT_DRY_RUN=true -e PROD_MIRROR_ENTERPRISES=5 prod-reflector` → `errors=0 guarded=0`, `changed` small (`core.enterprises` = the rename; the smoke PO; gold of hours computed on prod since the swap) | — |
| 11b | Delete the step-11 smoke PO/scan on **prod** if it should not stay (the mirror would copy it to staging too) | — |
| 11c | **Reflector ON**: `docker compose -f compose.staging.yml -p stack up -d --force-recreate prod-reflector` → `reflect pass … converged=true` within 2 min | — |
| 13 | Watch, for 1 h: `silver.equipment_values` for ent 5 rising; `gold.equipment_oee_hourly` for the 23 lines with `computed_at` advancing; `silver.plc_link_minutes.fail_ticks` per endpoint on **both** stacks (0 except L60); no `stmtcache`, `permission denied` or `ERROR` in the stream-engine, decoder or agent logs. **Staging mirror:** `prod-reflector` passes `converged=true`; after 15 min `SELECT check_id, ok, observed FROM ops.data_invariant_latest WHERE source = 'prod-reflector'` on staging → MR1–MR4 ok; `front.staging` as a Bispharma user shows "Bispharma (mirror)" + the read-only banner; a justify there → 403 with the production link | — |
| 14 | Superset: sync the assets and verify Reports for ent 5 (front4 → Reports) | — |

**Go/no-go gates:**
- every §2.3 gate is 0;
- step 11 is green;
- step 13 shows prod's live hour computing;
- staging's ent-5 ingest is unchanged;
- the staging mirror converged (MR1–MR4 ok) and refuses writes.

## 7. Rollback

Bispharma never left staging: staging's box instance, staging's cloud and the staging URLs keep working throughout.

| Scope | Action | Rehearsed |
|---|---|---|
| Box | `uninstall-prod.sh` (stops `packiot-prod` only) | yes: 10.4 s; staging instance untouched |
| Prod services | `docker compose -f compose.production.yml stop` | yes |
| Housekeeping timers (TS-free) | **First**: `sudo bash scripts/ops/install-analytics-housekeeping.sh --disable` on the DB host — they would otherwise run against the old DB once it is `packiot` again | — |
| Prod DB | Rename `packiot → packiot_bispharma_rolled_back` and `packiot_pre_promotion → packiot`. Then, to restore the old runtime too, stop the 2.27 container and `docker start timescaledb-2252`. The rolled-back DB opens only under the 2.27 image | yes: 22 ms SQL, image back in 2.3 s, **5.9 s total**; old layout served, `authentik`/`superset` intact |
| Staging mirror | Remove `PROD_MIRROR_ENTERPRISES` from staging's `/opt/packiot/.env`; recreate `edge-api barcode-service stream-engine prod-reflector` → staging is the master again (writes reopen, its engine resumes ent 5 from the next hour, the reflector idles). Everything production did until then is already on staging. Optional: `UPDATE core.enterprises SET nm_enterprise = 'Bispharma-Staging' WHERE id_enterprise = 5` on staging; peering terraform back to off later | inert-by-default proven in tests; switch is config only |
| Users | Back to the staging URLs (`front.staging`, `operator-bispharma.staging`), which accept writes again once the mirror is off | — |

## 8. User actions

1. Approve and merge the release-branch PR (or let it merge when green), and the release catch-up.
2. Terraform apply `production` (the 10-14 items plus 8449/nginx/DB pin, **plus `-var staging_mirror_enabled=true`**), then
   `terraform/staging` with `-var prod_mirror_peering_id=<pcx>`; re-run `nginx_setup.sh` on the app box.
3. Create the **prod ingest key**. Put it in `/opt/packiot/.env` (`AGENT_INGEST_API_KEY`) and, in the window, in
   `/root/.packiot-prod-ingest-key` on Bispharma's box.
4. Fill the prod `.env` keys (§6 T-1 step 3) and the 10-14 list (`READAPI_RO_PASSWORD`, `INTERNAL_API_KEY`,
   `ONBOARD_API_KEY`, the runner token B3).
5. Have CS run the PLC connection-resource check on site (§5.1) and confirm whether the legacy Pi is still polling.
6. Display name (approved 10-15): `Bispharma` on prod (§6 step 9a); staging shows `Bispharma (mirror)` automatically
   (the reflector's suffix, ADR-0064 D5).
7. Decide ent 5's api key on prod: rotate it (§6 step 9, recommended) or keep staging's.
8. Pick the window. Run §6 (steps 1–11 and 13–14 are the operator's; step 12 is on the customer's VM).
9. **At the go-live (not after a week):** tell Bispharma's users and CS the prod URLs (`front.prod`, `operator.prod`,
   `csadmin.prod`) — from step 2a staging refuses every ent-5 change and shows a banner pointing to production. Same
   Cognito logins (shared pool).
10. Decide (optional): backfill production's `silver.equipment_values` for the window gap (from the step-3 extract to the
   first production reading at step 12, ≈ 30–60 min) from staging's reader, so production's (and the mirror's) hours of
   the window are complete. Not done by this runbook (a write to production).
11. After a stable week:
   - decide when the staging box instance is retired (then move the fat-edge dashboard to the prod instance);
   - **(TS-free)** decide when the server drops the TimescaleDB library (ADR-0063 for prod): `packiot_pre_promotion` holds
     TimescaleDB objects and opens only with the library, so first archive it to S3 and drop it (as staging's F1
     `packiot`, 2026-10-15), then move the container to a plain pg16 image with `shared_preload_libraries=pg_stat_statements,auto_explain`
     (keep the D2 container stopped for rollback);
   - decide whether CPACK's prod mTLS tee is stopped at its box. After the swap, prod has no CPACK routes, so its
     batches are unmapped; watch the decoder's unmapped counter in the first hour.
