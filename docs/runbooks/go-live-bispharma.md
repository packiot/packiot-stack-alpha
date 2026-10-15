# Go-live runbook — Bispharma (enterprise 5) on the new production stack

**Status:** rehearsed end to end on throwaway clones on 2026-10-15
([report](go-live-bispharma-rehearsal-2026-10-15.md), on `staging`). **Nothing has run on production.** The go is the
user's: merging `release/prod-promotion-2026-10` into `production` deploys.

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
| D5 | **Sequences are floored above the old DB's ids** (`seq-floor.sql`) | Bispharma has no POs yet, so `core.production_orders` would restart at 1 while CPACK's prod history goes up to ~1.68 M. CPACK's later go-live into this DB then keeps its ids. 9 sequences are raised (POs → 1,676,663) |
| D6 | **Group id stays `BISPHARMASTAGING`** in prod | Topic routes, ADR-0061 device keys, the descriptor's `tenant` and the reader's metric suffixes are all keyed on it. Renaming is its own change, with its own rehearsal |
| D7 | **Raw values are not carried** (`bronze.equipment_values_raw`). Silver, gold, serving, events, box scans, samples, POs, shifts, targets, reasons and descriptors are | Bronze raw is staging's 90-day replay buffer; silver is the system of record. Prod raw starts at the go-live and is kept forever (`PROD_RAW_RETENTION=off`) |

## 2. Database migration

### 2.1 What travels (`scripts/promotion/bispharma/tenant_extract.py`, catalog-driven)

The generator reads staging's catalog. It stops if a table has no rule, so a table added to staging later must be
decided, not silently copied or dropped.
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
- `TRANSPLANT_MODE=tenant` restricts phase `data` to the retention catalog.
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
| Rows and content equal to the staging snapshot | `fingerprint-diff.py extract.out 12t-tenant-verify.sql.out`: count plus md5 of the ordered rows for every config table; for hypertables, count, first/last day and md5 of the per-day counts | 76/76 equal, 9,316,727 rows |
| No other tenant's rows anywhere | `purity` lines in the same output: 50 tables with a tenant key, 0 foreign rows | 0 |
| Referential integrity | phase `post` adds every FK after the load; an orphan is an `ERROR` | 0 errors |
| CHECK invariants | phase `checks`: 32 CHECKs re-added `NOT VALID`, then `VALIDATE` | 0 errors |
| Schema = staging | `compare-catalog.py cat-stg.json cat-next.json` | 0 missing/different (views: PG15→16 normalisation) |
| Grants, RLS, policies, role settings, jobs = staging | `compare-acl.py acl-stg.json acl-next.json` | 0. Jobs = staging's 27 minus 8 raw-retention policies and `purge_analytics_plain` (by design) |

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

**T-0, the window.** Bispharma keeps running on staging throughout; nobody is down.

| Step | What | Rehearsed time |
|---|---|---|
| 1 | Stop the prod app services (`docker compose -f compose.production.yml stop`; prod serves no customer today) | — |
| 2 | **Image swap** on the DB host: `docker rename timescaledb timescaledb-2252`; `docker run` D2 on the **same** `/opt/packiot/pgdata` with name `timescaledb` (the `database.tf` command). Keep the old container stopped, for rollback | 5 s to ready |
| 3 | **Staging extract** (READ ONLY, one REPEATABLE READ snapshot), streamed to S3 `promotion-rehearsal/<date>/` (a go-live prefix of the same bucket), then to the DB host | 55 s extract + 56 s upload + 10 s download |
| 4 | `xplant.sh roles … seqfloor` (§2.2) | 155 s on r7g.large (of which `tload` 109 s, `seqfloor` 28 s) |
| 5 | Gates (§2.3): fingerprint and purity diff, compare-catalog, compare-acl | ~1 min |
| 6 | **Swap**: terminate connections; `packiot → packiot_pre_promotion`; `packiot_next → packiot`; `start_background_workers()` in both; read back `current_database()` and the extension versions | 68 ms SQL |
| 7 | `XPLANT_DB=packiot xplant.sh refresh` in the background (the caggs are real-time meanwhile). Shred `/root/tenant5` | 438–563 s |
| 8 | `provision-db-role.py --env production` for stream-engine, legacy-replicator and operator-gateway (10-14 item 7) | — |
| 9 | Optional, recommended: **rotate ent 5's api key on prod** (`UPDATE core.enterprises SET api_key = gen_random_uuid()::text WHERE id_enterprise = 5`, on the host), so staging's key is not valid on prod. Put it in `OPERATOR_EDGE_API_KEY` | — |
| 10 | Merge release → `production`: the deploy runs the one-shots, then the services | one-shots 2 + 1 + 3 + 17 s; services healthy in 10 s |
| 11 | Smoke: edge-api PO create ×2 with one `Idempotency-Key` gives 1 PO; start; box scan; current; read-api `/v1/catalog` and `/v1/query` 1min/1hour with the ent-5 read key | all 200/201 |
| 12 | **Box install** (§5.2) | 0.6 s; first post at 19 s |
| 13 | Watch, for 1 h: `silver.equipment_values` for ent 5 rising; `gold.equipment_oee_hourly` for the 23 lines with `computed_at` advancing; `silver.plc_link_minutes.fail_ticks` per endpoint on **both** stacks (0 except L60); no `stmtcache`, `permission denied` or `ERROR` in the stream-engine, decoder or agent logs | — |
| 14 | Superset: sync the assets and verify Reports for ent 5 (front4 → Reports) | — |

**Go/no-go gates:**
- every §2.3 gate is 0;
- step 11 is green;
- step 13 shows prod's live hour computing;
- staging's ent-5 ingest is unchanged.

## 7. Rollback

Bispharma never left staging: staging's box instance, staging's cloud and the staging URLs keep working throughout.

| Scope | Action | Rehearsed |
|---|---|---|
| Box | `uninstall-prod.sh` (stops `packiot-prod` only) | yes: 10.4 s; staging instance untouched |
| Prod services | `docker compose -f compose.production.yml stop` | yes |
| Prod DB | Rename `packiot → packiot_bispharma_rolled_back` and `packiot_pre_promotion → packiot`. Then, to restore the old runtime too, stop the 2.27 container and `docker start timescaledb-2252`. The rolled-back DB opens only under the 2.27 image | yes: 22 ms SQL, image back in 2.3 s, **5.9 s total**; old layout served, `authentik`/`superset` intact |
| Users | Keep using the staging URLs (`front.staging`, `operator-bispharma.staging`). Nothing to tell them unless they were already switched | — |

## 8. User actions

1. Approve and merge the release-branch PR (or let it merge when green), and the release catch-up.
2. Terraform apply `production` (the 10-14 items plus 8449/nginx/DB pin), then re-run `nginx_setup.sh` on the app box.
3. Create the **prod ingest key**. Put it in `/opt/packiot/.env` (`AGENT_INGEST_API_KEY`) and, in the window, in
   `/root/.packiot-prod-ingest-key` on Bispharma's box.
4. Fill the prod `.env` keys (§6 T-1 step 3) and the 10-14 list (`READAPI_RO_PASSWORD`, `INTERNAL_API_KEY`,
   `ONBOARD_API_KEY`, the runner token B3).
5. Have CS run the PLC connection-resource check on site (§5.1) and confirm whether the legacy Pi is still polling.
6. Decide the display name: ent 5 is `Bispharma-Staging` on staging and travels as-is. Rename it on prod after the swap
   (`UPDATE core.enterprises SET nm_enterprise = 'Bispharma' WHERE id_enterprise = 5`)? Recommended.
7. Decide ent 5's api key on prod: rotate it (§6 step 9, recommended) or keep staging's.
8. Pick the window. Run §6 (steps 1–11 and 13–14 are the operator's; step 12 is on the customer's VM).
9. After a stable week:
   - tell Bispharma's users the prod URLs;
   - decide when the staging box instance is retired (then move the fat-edge dashboard to the prod instance);
   - decide whether CPACK's prod mTLS tee is stopped at its box. After the swap, prod has no CPACK routes, so its
     batches are unmapped; watch the decoder's unmapped counter in the first hour.
