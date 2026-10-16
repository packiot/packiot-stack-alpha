# Go-live rehearsal — Bispharma only, 2026-10-15

This rehearsed the Bispharma-only production go-live on throwaway clones:
- a clean prod DB with Bispharma's config and history copied from staging;
- prod-shaped services;
- a production box instance next to a staging one, fed by the repo's S7 simulator;
- a timed cutover and rollback.

The plan this rehearses is `docs/runbooks/go-live-bispharma.md` on `release/prod-promotion-2026-10`.

**No production change was made:**
- no prod host, prod DB, DNS, Terraform apply or `production` branch was touched, and the legacy systems were not
  touched either;
- staging was used **read-only**: one schema dump, two catalog/ACL reads, and one ent-5 extract (55 s, a single
  `REPEATABLE READ READ ONLY` snapshot);
- Bispharma's real box got **read-only** SSM commands only. `uname`/`free`/`df`, `docker ps`/`stats`, a directory
  listing, the three non-secret `reader.config.json` fields (group, poll interval, target URLs), and `sha256sum` of
  the bundle files. `.env` files were never read;
- the real PLC was not contacted.

## Verdict

**GO, conditional on the user actions** (the runbook's §8):
- the release-branch PR with the fixes below;
- Terraform apply (8449 + the 10-14 items);
- the prod `.env` keys and the prod ingest key;
- the on-site PLC connection-resource check.

The rehearsal found **eight defects that would have broken or corrupted the go-live**. All are fixed in the release PR
and re-proven:

| # | Defect | Effect at go-live | Fix |
|---|---|---|---|
| 1 | `build.py` on a **clean** server: staging grants to `bi_owner` and `superset_ro`, which `roles` never created | Build stops (it only worked because the old prod server had them) | `CLEAN_SERVER_ROLES`, create-if-missing (a no-op on a server that has them) |
| 2 | `build.py` crashed on an empty target catalog (`P['tables']` is NULL) | Build stops | `or []` |
| 3 | Phase `data` re-ran the business backfills on rows that came from staging | **Bispharma's curated config silently rewritten**: `t-ideal-speed-best-demonstrated` re-derived machine M682's `production_speed` 110 → 241, and with it its line's targets. The t244 descriptor inserts would add other tenants' rows | `TRANSPLANT_MODE=tenant` keeps only the retention catalog. Caught by the fingerprint diff (2 tables differed in run 1, 0 in run 2) |
| 4 | Prod `template1` carries TimescaleDB 2.25.2 | `packiot_next` would inherit 2.25.2 even under the 2.27.0 image | `CREATE DATABASE … TEMPLATE template0` (rehearsed: 2.27.0) |
| 5 | **Prod `sparkplug-decoder` reaches the DB through pgbouncer** (transaction pool) | Every periodic reload fails (`prepared statement "stmtcache_…" does not exist`), so the counters-only rates and OEE margins **never load**. This also applies to CPACK on prod | `POSTGRES_HOST: ${POSTGRES_HOST_UPSTREAM}` (staging's decoder is already direct): 0 errors, 112 rate entries loaded |
| 6 | Prod has **no thin-reader front door** (no `sparkplug-agent-shared`, no 8449 vhost or SG rule) | The production box has nowhere to post | Agent service (only `bispharma.yaml` mounted), nginx 8449 vhost identical to staging's, SG `8449` from `200.153.25.2/32` |
| 7 | edge-api's box generator renders one instance per box | A second instance collides on container names. Deployed into `/opt/packiot`, it would **replace the staging reader**. It would also tee prod batches into the staging helper and the staging fat-edge agent | `render-box-instance.mts`: the generator unchanged plus an asserted overlay (own project, names, helper port 1890, no fat-edge tee), and `install-prod.sh` / `uninstall-prod.sh` |
| 8 | Prod sequences restart at the tenant's max | `core.production_orders` would restart at **1**, colliding with CPACK's old prod ids (up to 1,676,663) when CPACK goes live into this DB | `seq-floor.sql` raises 9 sequences above the old DB's max (via dblink, before the swap) |

Plus three tooling corrections:
- `compare-acl.py` ignored staging's live `pg_temp_*` engine tables (42 false positives);
- `tverify` must run before `policies`, because a job rebuilds `serving.downtime_events_resolved` once registered;
- the ent-5 `stream-engine` knobs: line-lead, the live CPAC deriver, the stale closer.

## Clones and why

| Clone | What | Why this shape |
|---|---|---|
| **A** `i-0f0a3292b1ef7cf59` m7i.xlarge (4 vCPU / 16 GB), Debian 13 x86_64, prod DB subnet, SG with no ingress | A fresh `timescale/timescaledb:2.27.0-pg16` (digest `sha256:51eb3bcd…`) DB: the clean build twice (run 1 found defect 3), then the clone DB behind the services | A clean start carries no prod data, so a plain instance with the prod image is enough for the build. It is the same OS/arch as the box |
| **B** `i-0bd687020b343ab7a` r7g.large from the prod DB AMI of 2026-10-14 (`ami-081794d61062c6425`), same subnet and SG | The real prod server shape: the image swap on prod's pgdata, the build next to the old DB, the swap, the refresh, and the rollback | D1/D2 put the new DB **on the old server**, so the image swap and the coexistence with `authentik`, `superset` and the old CPACK DB had to be proven on prod's own data directory |
| **Services + box** on the operator's laptop (Docker, project `bgreh`), DB = clone A over an SSM port-forward | Prod-shaped services from `compose.production.yml` (release branch with the fixes), least-privilege logins, plus both box instances, the S7 simulator, and a sink standing in for staging's ingest | See "Deviations" |

### Deviations from the brief

**The services and the box clone ran on the laptop, not on a throwaway VM.** The classifier blocked uploading the
source tree to S3 as data exfiltration. Building the services on a VM needs that source, so they were built locally
instead. The DB stayed on clone A: its data holds Bispharma's api keys, so the extract was **never** materialised
locally.
- Consequences:
  - the box instances ran on the laptop's Docker (Arch, x86_64, Docker 29, compose 5.1) instead of Debian 13;
    coexistence is a Docker-level property (names, ports, volumes, projects), so the proof holds;
  - the prod reader posted over plain HTTP to the agent (`--ingest-url` of the same script). The nginx 8449 TLS
    front-door is byte-identical to staging's live one;
  - `compose.production.yml`'s `172.18.0.x` statics were rewritten to `172.31.0.x` (172.18/16 is in use on the
    laptop);
  - the mTLS 8883 listener was omitted (CPACK's path);
  - stream-engine and the decoder used `CREDS_SOURCE=env` with the **same** least-privilege identities instead of
    Secrets Manager.
- Ent 5's api key was rotated to a throwaway value **on clone A only**, after verification, so the smoke test never
  handled the real key.
- The staging-shaped box instance posted to a local sink, never to staging.

## Timings

| Step | Time | Notes |
|---|---|---|
| Staging extract (READ ONLY, one snapshot) | **55 s** | 76 tables, 9,316,727 rows, 2.3 GB of COPY text; plus 56 s upload to S3 and 10 s download |
| Image swap on prod pgdata (B): stop 2.25.2, start 2.27.0 | **5 s** to ready | All 5 DBs open. Old `packiot` stays at 2.25.2 (the image ships that library): 5.84 M rows read, cagg reads, **14/14 jobs Success** |
| Build `roles` → `tverify` (A, run 2) | **111 s** | `tload` 94.5 s; all phases 0 errors |
| Build `roles` → `seqfloor` (B, prod shape) | **155 s** | `tload` 108.6 s, `seqfloor` 28.3 s; `create` gives TS 2.27.0 |
| Swap | **9 ms** (A) / **68 ms** (B) SQL | Read-back: `packiot` = 2.27.0, 128 ent-5 equipments, 2 enterprises; `packiot_pre_promotion` = 2.25.2, 19,789 POs |
| Cagg refresh after the swap | **438 s** (A) / **563 s** (B, r7g.large) | Background; the caggs are real-time meanwhile |
| Deploy-shaped start | one-shots `db-schema-f3` 1 s (skips: F3 present), `db-knex-baseline` 3 s, `db-migrate` 17 s ("Already up to date"); services healthy in **10 s** | `db-init-bootstrap` needs `AUTHENTIK_DB_PASSWORD` (present in prod's `.env`) |
| Box prod-instance install (`install-prod.sh`, sandboxed paths) | **0.6 s**; first PLC cycle at **19 s** | pip installs python-snap7 at start, as on the box today |
| Rollback | see §Rollback | |

## Evidence

**Data**
- `fingerprint-diff.py`: **76/76 tables equal** to the staging snapshot. Config tables are compared by an md5 of the
  ordered rows; hypertables by count, first/last day and an md5 of the per-day counts. 9,316,727 rows.
- **Purity:** 0 rows of any other tenant in 50 tenant-keyed tables.
- **FKs:** all added by `post` with 0 errors, so no orphans. The 32 CHECKs were `VALIDATE`d.
- On clone B, `serving.downtime_events_resolved` (3,091 rows) differed in content only: its job had already rebuilt it,
  and that is why `tverify` now runs before `policies`.

**Schema and access**
- `compare-catalog`: 0 missing/different (views: PG15→16 normalisation).
- `compare-acl`: 0. Jobs = staging's 27 minus the 8 raw-retention policies and `purge_analytics_plain`, by design
  (`PROD_RAW_RETENTION=off`).

**Least privilege**
- `stream_engine` ran the engine: 8 sessions, as `oeecloud-worker` / `-analytics`.
- `readapi_ro` served read-api and is RLS-fenced (0 rows without a tenant).
- The decoder and agent ran on their own rabbit users.

**Smoke tests (ent 5, line L57, throwaway key)**
- edge-api:
  - PO create ×2 with one `Idempotency-Key` → **201/201, 1 PO, 1 key**;
  - start 201 (runtime row opened); box scan **201** (`labelSeq 1`); current 200 (status 2);
  - 4 audit rows.
- read-api (ent-5 read key):
  - `/healthz` 200, `/v1/catalog` 200;
  - `/v1/query` `1min` **200** (1.0 MB) and `1hour` **200** (557 KB), cagg reads as `readapi_ro`.

**Ingest, end to end**
- Path: S7 simulator (`services/sparkplug-decoder/cmd/s7-softplc`, DB1) → **production** reader (`packiot-prod`,
  23 endpoints, the generator's own `PLC_HOST_*` overrides) → `sparkplug-agent-shared` (3,864 batches accepted) →
  mosquitto → decoder → RabbitMQ `stream-engine-q-bispharmastaging` → stream-engine → silver.
- Silver: ent 5 rows from 45 equipments; the leads' 1-min cagg shows 240/min.
- **Gold:** the engine computed the live hour for **all 23 Bispharma lines**. In the 02:00 hour, from simulator data
  only, L56 and L57 reached net 600 with 148 s running (`computed_at` 02:02:27).
- Expected simulator artefacts, not defects:
  - offsets 16 and 20 fail on the simulator's 16-byte data block;
  - the first increment is clamped (the baseline is staging's real counter);
  - OEE is above 1, because the simulated speed exceeds the BDR ideal and the data is uncapped by policy.

**Coexistence (both instances up at once)**

| | staging-shaped | production |
|---|---|---|
| Project / dir | `packiot` (+ `fatedge`) | `packiot-prod` |
| Containers | `packiot-edge-reader`, `packiot-nodered-helper`, `onprem-*` | `packiot-edge-reader-prod`, `packiot-nodered-helper-prod` |
| Listeners | `127.0.0.1:1880`, `127.0.0.1:9104`, `1881` | `127.0.0.1:1890` |
| Volumes | `packiot_nodered-data`, `fatedge_*` | `packiot-prod_nodered-data` |
| Memory / CPU | reader 18.6 MiB / 3.7 %, helper 50 MiB | reader 17.3 MiB, helper 47.6 MiB |
| Posts | 3,951 to the sink (stood in for staging) | 3,864 to prod's agent |

- `install-prod.sh` printed the staging containers as **untouched** (up 7 min).
- Fidelity: rendered from prod's copied descriptor, the generator's staging bundle is **byte-identical** to the real box's
  `compose.edge.yml`, `reader.py` and `reader.config.json` (sha256 on the box). The fat-edge compose is the same size.

## PLC second reader: proceed (details in the runbook, §5.1)

- **PLCs:** S7 (rack 0 / slot 2, the S7-300 family), 23 endpoints, 91 DINT tags. The configured poll is 5 s (read on
  the box); the effective cycle is about 12 s.
- **Connections:** one PG-type connection per PLC per cycle, held about 10 ms (SP) or about 200 ms (BISNAGO). A second
  reader doubles a very small load (about 0.8 PDU/s per PLC) and needs at most one more connection resource in rare
  overlaps. A CPU 315-2 PN/DP has 16 resources.
- **Before the go:** the on-site connection-resource check. **Fallback:** one reader with two targets.

## Rollback (clone B)

| Step | Time | Read-back |
|---|---|---|
| DB names back (`packiot → packiot_bispharma_rolled_back`, `packiot_pre_promotion → packiot`) | **22 ms SQL** (97 ms total) | — |
| Image back to 2.25.2-pg16 (stop the new container, start the old one, same pgdata) | **2.3 s** | — |
| **Total** | **5.9 s** | The old layout is served: `packiot` at 2.25.2, 19,789 POs, last value 2026-10-14 04:12 (the AMI). `authentik` 159 tables and `superset` 47, intact |

- The rolled-back Bispharma DB (2.27.0) cannot be opened under 2.25.2 (`timescaledb-2.27.0` missing). That is expected:
  it is kept for forensics and opens again under the 2.27 image.
- Box rollback (`uninstall-prod.sh`, sandboxed): **10.4 s** (the reader's 10 s stop grace). The staging instance stayed
  up (16 min) and kept posting.
- Service rollback: `docker compose stop`. Bispharma itself never left staging during the rehearsal.

## Open observations (not blockers)

- **The fat-edge transformer cannot run with the current `sparkplug-decoder` build.** It fetches
  `packiot/staging/rabbitmq-edge-transformer-creds` from Secrets Manager **before** it honours `LOCAL_DECODE_ONLY`
  (`cmd/edge-transformer/main.go`), so it crash-loops without AWS credentials. The box runs a 2026-09-01 build that is
  healthy. Check this before any fat-edge rebuild on a box.
- **CPACK's prod tee (mTLS 8883)** will reach a prod with no CPACK routes. Watch the decoder's unmapped counter after the
  go-live; stopping that tee is a user decision.
- The local fat-edge stand-in only proved the footprint (names, ports, volumes), not its function. Its agent restarted
  on the placeholder uplink host in the stored `agent_yaml` artifact (the box runs a hand-edited one), and its
  transformer hit the secret-fetch issue above.
- `README.md` in the generated bundle differs from the box's copy: it lists generation gaps, such as the placeholder
  ingest key. It is not executed.

## Resources and cost

All created today and **deleted the same day** (verified: 0 instances and 0 volumes tagged
`Purpose=promotion-rehearsal-throwaway`, the SG deleted, the S3 prefix empty).

**AWS**
- **Clone A** `i-0f0a3292b1ef7cf59`: m7i.xlarge with an 80 GB gp3 volume (delete-on-termination). Up 01:26 → 02:10 UTC.
- **Clone B** `i-0bd687020b343ab7a`: r7g.large from `ami-081794d61062c6425`, 100 GB gp3 (delete-on-termination). Up
  01:48 → 02:09 UTC. Its volume holds a prod-data copy; it was deleted with the instance.
- **SG** `sg-07becbe9005961e74` `promotion-rehearsal-bg-20261015`: no ingress, egress 80/443 only.
- **S3** `s3://packiot-staging-db-backups-639178078294/promotion-rehearsal/20261015/`: the schema dump, catalog, ent-5
  extract (contains api keys; deleted), build outputs and extract log.
- No snapshots, AMIs or EIPs were created. The instance profile is the existing SSM-only `AWSCloud9SSMInstanceProfile`.

**Staging DB host:** `/root/bg-extract`, and `/tmp/tenant5` in the container (deleted right after the upload).

**Laptop**
- Removed:
  - Docker project `bgreh`: containers, volumes and network;
  - the box projects `packiot`, `fatedge` and `packiot-prod`, with their volumes;
  - `bgreh-s7sim`, `bgreh-sink`, `bgreh-dbrelay`, the network `bgreh-plc`;
  - the images `bgreh-*`, `packiot-sparkplug-decoder:local`, `alpine/socat`, `python:3.12-slim`;
  - the SSM port-forward.
- Left: Docker build cache from the five image builds (no host-wide prune by rule), and `curlimages/curl` /
  `postgres:16-alpine` (may predate this run).
- Throwaway credentials (`/var/tmp/bg-rehearsal/run/creds.env`, generated locally for the clone only) were deleted.

**Cost:** about **$0.22**: clone A 44 min × $0.2016/h ≈ $0.15, clone B 21 min × $0.1071/h ≈ $0.04, EBS ≈ $0.02,
S3/requests < $0.01. The cap was ~$3.
