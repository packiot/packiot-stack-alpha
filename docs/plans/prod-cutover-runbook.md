# Production cutover runbook (verified, ordered) — #190

**Every step below was dry-rehearsed / hard-verified on 2026-09-07** (branch
`forward-port/prod-ready`). This is the exact, ordered sequence to take the
greenfield F3-native production stack live. Each step is human-triggered; the
**merge is the deploy** (`deploy-production.yml` fires only on push to `production`).

## Preflight (verify before touching anything)

```bash
# You are cutting over FROM this branch (off origin/production, full infra + de-risk):
git checkout forward-port/prod-ready
git log --oneline origin/production..HEAD          # 6 commits (#190 forward-port)

# Tooling the gated scripts need (both confirmed present on this machine):
command -v session-manager-plugin && command -v script   # required for capture/parity SSM PTY
```

### ⚠ THE TERRAFORM TRAP (hard-verified)
`origin/feat/prod-first-boot-hardening` is **1703 lines behind** `origin/production`
on terraform — it is MISSING `historian.tf` (377), `superset.tf` (365),
`bi_edge.tf` (342), `edge.tf` (497). **A `terraform apply` from that branch would
DESTROY** the historian (S3+Athena cold store), Superset, BI-edge, and edge
infrastructure. **Always run terraform from `forward-port/prod-ready` (= `production`
after merge)**, which carries the full infra. `git diff origin/production HEAD --
terraform/` on this branch shows only the additive `app_init.sh` HIST_* change.

## Step 1 — Regenerate the F3 snapshot (THE correctness crux)
The committed `00-packiot_analytics-schema.sql` + `MANIFEST.f3-target` are a
coherent **pre-rename placeholder** (both `runtime_*`, frozen 2026-08-20). The
`oee_*` (rename) + #186 (dropped grains) schema exists ONLY in live staging
`packiot_analytics`. Capture it (SELECT-only, schema-only pg_dump on the staging
DB EC2 `i-064bb36d…`):

```bash
CONFIRM=yes ./scripts/capture-f3-snapshot.sh
#   → rewrites db/init-f3/snapshot/00-packiot_analytics-schema.sql (SAME filename —
#     no dual-00; db-schema-f3 globs snapshot/00-*.sql), strips cagg/debris blocks.
# Refresh the committed MANIFEST baseline to match (post-rename oee_*):
./scripts/prod-f3-schema-parity-check.sh capture-target > db/init-f3/MANIFEST.f3-target
git add db/init-f3/snapshot/00-packiot_analytics-schema.sql db/init-f3/MANIFEST.f3-target
git commit -m "cutover: regenerate F3 snapshot + MANIFEST from live packiot_analytics (oee_* + #186)"
```
The strict `05`/`10`/`15` layer is already committed; `15` (read-api composite-type
fixes) is idempotent and required (9 `/v1/query` datasets 500 without it).

**Pre-validated (2026-09-07, read-only `capture-target` vs the committed placeholder):**
the regen will take the MANIFEST from **307 → 255** objects: **−137** (renamed-away
`equipment/area/site_runtime_*` tables, #186 dead grains, #182 cruft) and **+85**
(the `*_oee_*` + `*_live_*` rename targets services read). Live staging is confirmed
correctly post-rename: tables are `oee_*`, and the `piot_create_*_runtime_*`
provisioning FUNCTIONS keep only a stale *name* — their bodies correctly write
`*_oee_*` (verified `piot_create_equipment_runtime_shift` body inserts/updates
`equipment_oee_shift`). No rename gap. #186 grains confirmed absent from live.
(Stale provisioning-function *names* are a cosmetic clean-trails item for a future
analytics-naming pass — NOT a cutover blocker.)

## Step 2 — Correctness GATE (do NOT skip; this is what stops silently-wrong OEE)
Assemble a throwaway TimescaleDB from `db/init-f3/`, then diff its shape against
LIVE staging (the gate captures TARGET live — it does NOT trust the committed file):

```bash
# spin a local pg, run db/init-f3/assemble.sh into it, then:
CANDIDATE_DSN='postgresql://postgres:postgres@localhost:5599/packiot' \
  ./scripts/prod-f3-schema-parity-check.sh gate
#   PASS  → F3_MISSING = 0  (candidate is superset of live F3 shape). Proceed.
#   FAIL  → missing F3 objects; seeding now = silently-wrong OEE. Fix before Step 5.
```
**Prod is NOT safe to seed until this PASSes.**

## Step 3 — Terraform (from `forward-port/prod-ready` ONLY)
```bash
cd terraform/production
terraform plan -out=/tmp/prod.plan
```
Plan review checklist — **reject the plan if any of these appear:**
- Any `destroy`/`replace` of `aws_s3_bucket.*historian*`, Athena workgroup/db,
  `aws_cloudfront_*`, ACM certs, WAF, `superset`, `bi_edge`, `edge` resources.
- DB EC2 (`aws_instance.db`) replace (would wipe `/opt/packiot/pgdata`).
- Route53 zone deletes.
Expected: additive/first-boot only (runner, app box user_data refresh with the new
`app_init.sh`). Then `terraform apply /tmp/prod.plan`.

## Step 4 — Box secrets (`.env` from Secrets Manager)
`app_init.sh` builds `/opt/packiot/.env`; **all required + bare compose vars are
covered** (verified: 0 unset). New this cutover — the historian is **opt-in** and
its vars default-safe, so nothing here blocks the deploy. To enable the historian
LATER (Appendix), add to the `packiot/production/app` secret: `hist_gw_password`,
`historian_bucket`, `hist_aws_key`, `hist_aws_secret` (+ a scoped read-only IAM user
for the bucket — `historian.tf` uses role-based Athena and mints no static key).

## Step 5 — Merge = deploy
```bash
git checkout production && git merge --no-ff forward-port/prod-ready && git push
# deploy-production.yml: docker compose -f compose.production.yml build && up -d
#   --remove-orphans, then per-service ERROR grep. Watch it green.
```
The historian-gateway is profiled OFF → it will NOT start (and won't be removed as
an orphan). The other 24 services start.

## Step 6 — Post-deploy verification
- `docker compose -f compose.production.yml ps` — all up/healthy.
- `adr0032-f3-fidelity-check.sh` — live DATA/OEE health once a client is onboarded.
- Prometheus targets all `up` (mirror the staging check: `curl localhost:9090/api/v1/targets`).
- Then: DNS, first-client onboard/seed (CS Admin), `COGNITO_AUTH_ENABLED=true` flip,
  traffic cutover.

## Step 7 — Post-carry cleanup
- `ALTER TABLE users DROP COLUMN operator_pw_hash` on the PROD db (only after prod
  edge-api carries #159 — it now does). See `docs/plans/operator-pw-hash-retirement.md`.
- Unblocks **#159** (retire the Firebase auth dual-path flags once prod is Cognito-only).

## Appendix — enabling the historian gateway (opt-in, post-cutover)
Once there is cold history to serve + the S3 key + secrets are provisioned:
```bash
docker compose -f compose.production.yml --profile historian up -d historian-gateway
# first boot runs refresh_hist_cutover() (up to ~20m parquet scan; start_period covers it)
```
Add a `blackbox-historian` scrape + `HistorianGatewayDown` alert to prod monitoring
(already present on staging) when #180's observability lands in prod.
