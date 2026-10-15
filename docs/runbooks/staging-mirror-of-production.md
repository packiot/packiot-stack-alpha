# Runbook — staging as a read-only mirror of production (ADR-0064)

**When:** a tenant goes live on the new production stack and production becomes its source of truth. First use:
Bispharma (enterprise 5), go-live runbook `docs/runbooks/go-live-bispharma.md` §6 on `release/prod-promotion-2026-10`.
**Decision:** [ADR-0064](../adr/0064-staging-mirror-of-production-after-go-live.md).

**One switch:** `PROD_MIRROR_ENTERPRISES=<id>` in staging's `/opt/packiot/.env`. It is read by four services:

| Service | With the switch on |
|---|---|
| edge-api | every POST/PUT/PATCH/DELETE of the tenant → 403 `MIRROR_TENANT_WRITE_BLOCKED` ("make this change in production"); `GET /api/environment/mirror-status` → `mirror: true` (SPAs show the read-only banner) |
| barcode-service | scans of the tenant → 403 |
| stream-engine | skips the tenant in every job that writes a reflected table (rollups, UNS views, PO recalc, stop minting/closing, po-control) |
| prod-reflector | every minute, converges the tenant's staging rows to production's (production wins); MR1–MR5 invariants every 15 min |

Staging's own PLC reader keeps feeding `silver.equipment_values` (minute charts, rollback base). Everything else of
the tenant on staging is production's.

**Never** edit a mirrored tenant on staging, not even through CloudBeaver/pgweb: the reflector reverts it within a
minute and raises ProdMirrorStagingWrites.

---

## 1. Prerequisites (T-1, no customer impact)

1. **Code on staging:** packiot-stack (prod-reflector, stream-engine, barcode-service, this runbook) and edge-api
   `staging` deployed. Everything is inert while the variable is unset (`prod-reflector` logs *idle*).
2. **Staging DB — roles** (on `packiot-staging-db`, as postgres, the
   [add-a-migration](../wiki/build/develop/add-a-migration.md#8-dry-run-on-staging) way): dry-run
   `db/migrations/t-prod-reflector-roles/01-up.sql` with `COMMIT` → `ROLLBACK`, apply, run `verify.sql`
   (V1–V6 as labelled; I1 still `f`).
3. **Staging host — the staging login:** `python3 /root/provision-db-role.py --service prod-reflector`
   → secret `packiot/staging/prod-reflector-db-creds`; re-run `verify.sql`: I1 = `t`.
4. **Network (terraform, the user applies):**
   - `terraform/production` (release branch): `terraform apply -var staging_mirror_enabled=true` → peering
     `packiot-production-staging-mirror`, route 10.10.0.0/16 in the production private route table, DB SG ingress
     5432 from 10.10.0.228/32. Note the output `staging_mirror_peering_id`.
   - `terraform/staging`: `terraform apply -var prod_mirror_peering_id=<pcx-…>` → route 10.20.10.89/32 in the staging
     public route table; the app role's read of `packiot/production/prod-reflector-ro-db-creds` (already in the
     policy, harmless before the secret exists).
   - Check from the staging app host: `docker run --rm postgres:16-alpine pg_isready -h 10.20.10.89 -p 5432`
     → `accepting connections`.

## 2. Switch on (T-0, inside the go-live window)

Order matters: the write block goes on **before** the staging extract, so the snapshot production is built from is
final (nothing can be written on staging between the extract and the switch).

| Step | Where | What | Check |
|---|---|---|---|
| M1 (before go-live step 3) | staging app host | add `PROD_MIRROR_ENTERPRISES=5` to `/opt/packiot/.env`; `docker compose -f compose.staging.yml -p stack up -d --force-recreate edge-api barcode-service stream-engine` | a PO create on ent 5 with its key → 403 `MIRROR_TENANT_WRITE_BLOCKED`; ent 3 unchanged; `docker inspect stream-engine --format '{{range .Config.Env}}{{println .}}{{end}}' \| grep PROD_MIRROR` = 5 and the three containers healthy (a bad value fails their boot) |
| M2 (after go-live step 4, `seqfloor`) | production DB host | `SELECT min(last_value) FROM pg_sequences WHERE schemaname IN ('core','gold','silver','bronze','config','identity') AND last_value IS NOT NULL` ≥ 1000000000 (the id block) | MR4 will check it continuously |
| M3 (after go-live step 6, swap) | production DB host | apply `db/migrations/t-prod-reflector-roles/01-up.sql` to `packiot` (idempotent; the transplant may already have carried the roles), `verify.sql` | V1–V6 |
| M4 | **production** app host | `python3 /root/provision-db-role.py --service prod-reflector-ro --env production --db-name packiot --db-host 10.20.10.89 --admin-host 10.20.10.89` | step 4 of the script: login OK as `prod_reflector_ro`, `default_transaction_read_only=on` |
| M5 (after go-live step 11 smoke + the rename/rotation, step 9) | staging app host | **dry run**, 3 min, nothing written: `timeout 180 docker compose -f compose.staging.yml -p stack run --rm -e PROD_REFLECT_DRY_RUN=true -e PROD_MIRROR_ENTERPRISES=5 prod-reflector` | log `reflect pass … dry_run=true`, `errors=0`, `guarded=0`; `changed` small (expected: `core.enterprises` = the name, plus whatever production did since the extract) |
| M6 | staging app host | `docker compose -f compose.staging.yml -p stack up -d --force-recreate prod-reflector` | within 2 min `docker logs prod-reflector` shows `reflect pass … converged=true`; container healthy; Prometheus `prod_reflector_last_converged_timestamp_seconds{enterprise="5"}` set |
| M7 (+15 min) | staging DB | `SELECT check_id, ok, observed, detail FROM ops.data_invariant_latest WHERE source = 'prod-reflector'` | MR1–MR4 `ok`, MR5 `ok` (or `warn` listing tables to classify) |
| M8 | browser | `front.staging` / `operator-bispharma.staging` as a Bispharma user | enterprise shows **Bispharma (mirror)**; read-only banner with the production link; a justify → refused with the production message |

## 3. Operating it

| Signal | Meaning | Action |
|---|---|---|
| ProdMirrorStale / MR3 | no converged pass for 15 min | `docker logs --since 30m prod-reflector`: `permission denied` → grants (re-run 01-up.sql on that side); connection errors → peering/SG/secret; `production has no such enterprise` → wrong DB behind the secret |
| ProdMirrorGuarded `empty_source` | production returned **no** rows for a table staging has | production login lost its tenant stamp / grant, or production really emptied the table. Never raise the limit before knowing which |
| ProdMirrorGuarded `max_deletes` | > 2000 rows to delete in one table | a production clean-up or a bug. If legitimate: `PROD_REFLECT_MAX_DELETES=<n>` in `.env`, recreate prod-reflector, remove it afterwards |
| ProdMirrorStagingWrites | a mirrored row changed **on staging** | something on staging wrote the tenant (a route the block misses, a DB console, an engine job not folded out). The table is in the alert; find the writer (`identity.user_logs`, container logs). Production already won |
| MR1 / MR2 failing, reflector converged | a table keeps differing after its pass | `docker logs prod-reflector \| grep 'not converged'` names table + bucket (e.g. DML on a compressed chunk) |
| ProdMirrorUnclassifiedTables / MR5 | a migration added a tenant-keyed table | decide it in `services/analytics-sync/internal/mirror/spec.go` (Reflected or Local) and the migration's grant list |

Pausing the mirror without reopening writes: `docker compose -f compose.staging.yml -p stack stop prod-reflector`
(staging stays blocked and frozen; restart it to catch up — it is stateless).

## 4. Rollback (the production go-live is rolled back)

Staging becomes the master again.

1. Remove `PROD_MIRROR_ENTERPRISES` from `/opt/packiot/.env`.
2. `docker compose -f compose.staging.yml -p stack up -d --force-recreate edge-api barcode-service stream-engine prod-reflector`
   → writes reopen, the engine resumes the tenant from the next hour, the reflector idles.
3. Optional: rename back — `UPDATE core.enterprises SET nm_enterprise = 'Bispharma-Staging' WHERE id_enterprise = 5;`
   on the staging DB (the reflector had set "Bispharma (mirror)").
4. Optional, later: `terraform/staging` apply with `prod_mirror_peering_id=""`, then `terraform/production` with
   `staging_mirror_enabled=false`; `rollback.sql` of `t-prod-reflector-roles` on either side.

Everything production did until the rollback is already on staging (it was mirrored). The MR rows age out of
`ops.data_invariant_latest` within a day.
