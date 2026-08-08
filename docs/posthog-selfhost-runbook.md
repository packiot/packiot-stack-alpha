# Self-hosted PostHog — bring-up runbook

**Purpose:** stand up a **self-hosted PostHog** as the analytics backend for
front4's PostHog integration. front4 posts events to a **first-party
reverse-proxy subdomain** (the ad-blocker dodge), which proxies to the PostHog
`web` container.

**Status:** SCAFFOLD landed (this PR). Nothing is deployed. PostHog is a
**deliberate, hand-brought-up** service — mirrors how the `client-ingest` / CPACK
profile is gated and never started by a routine deploy.

**What this PR added**
| File | Role |
|------|------|
| `compose.posthog.yml` | Pinned PostHog service graph, own compose project `posthog`, own network `posthog-net`, **`posthog` profile** gates every service. |
| `compose.posthog.env.example` | The `.env` keys the compose reads (no real values). |
| `terraform/production/secrets.tf` | `packiot/production/posthog` secret (Django secret + dedicated PG + minio creds), terraform-managed. |
| `terraform/production/user_data/nginx_setup.sh` | `e.<domain>` capture vhost (sentinel-gated). |
| `terraform/production/user_data/app_init.sh` | Commented codification note (secret → `.env`). |
| `.gitignore` | Ignores the vendored `posthog/` checkout + `.env.posthog`. |

**Pinned version:** `posthog/posthog:release-1.43.0` (published 2023-01-16).
**Chosen subdomain:** `e.prod.packiot.app` (covered by the existing
`*.prod.packiot.app` wildcard cert — no new cert needed).

---

## 0. Why a pinned "classic" PostHog release?

As of 2026 PostHog's `master` self-host compose has grown to ~40 services
(Temporal, Elasticsearch, SeaweedFS, Browserless, ~20 build-from-source Rust
microservices) and PostHog no longer publishes semver images — only `:latest`,
`:master` and per-commit `:sha-*` tags. `release-1.43.0` is the last widely
deployed **classic** self-host topology whose entire graph is image-pullable and
readable in one file: `db · redis · clickhouse · zookeeper · kafka ·
object_storage(minio) · web · worker · plugins · migrate · asyncmigrationscheck`.

That is exactly the graph `compose.posthog.yml` vendors (adapted from PostHog's
official `docker-compose.base.yml` + `docker-compose.hobby.yml` at that tag).

**Upgrade caveat:** moving to a newer PostHog later is not a tag bump — it means
migrating to their newer, much heavier compose topology. Budget for that
separately. For an internal front4 analytics backend, the pinned classic release
is the pragmatic, stable choice.

---

## 1. Sizing decision — DEDICATED box vs co-locate  ⭐ (read + decide)

PostHog is **heavy**: ClickHouse + Kafka + Zookeeper + a dedicated Postgres +
Redis + minio + 3 app containers. Realistic floor is **~4 GB+ RAM** and several
CPUs; ClickHouse and Kafka both want headroom.

The OEE app box already runs the **full OEE stack** (edge-transformer,
oeecloud-worker, Hasura, pgbouncer, authentik, grafana/loki/prom, refdata,
mosquitto, …). Stacking PostHog on top risks **starving the OEE pipeline** —
ClickHouse merges + Kafka can spike CPU/RAM/IO and evict the OEE workers' page
cache. The OEE box is the revenue path; analytics must never degrade it.

| Option | What it means | Trade-off |
|--------|---------------|-----------|
| **DEDICATED box (RECOMMENDED)** | A separate EC2 (e.g. `t3.large`/`m6i.large`, ≥4 GB RAM, ≥40 GB gp3 for ClickHouse+minio growth) running only `compose.posthog.yml`. front4 → `e.prod.packiot.app` → nginx on that box (or the app box) → PostHog. | +Isolation (PostHog can never starve OEE). +Independent scaling/restart/backup. −One more instance to run + a bit more terraform (an EC2 + SG + the DNS A record → its EIP). |
| **Co-locate on the OEE app box** | Add `compose.posthog.yml` (profile `posthog`) alongside the OEE stack; nginx proxies `e.` → `127.0.0.1:8000`. | +No new instance. −**Resource contention** with the OEE pipeline; a ClickHouse/Kafka spike can hurt OEE. Add `mem_limit`/`cpus` reservations and watch closely if you go this way. |

**Recommendation: DEDICATED box.** The compose is written to support either —
the only difference at proxy time is the vhost's `proxy_pass` target (loopback
for co-locate; the PostHog box's private IP for dedicated). The rest of this
runbook notes the fork where it matters.

> The scaffold's terraform does **not** provision a dedicated EC2 — that's a
> deliberate follow-up (an `aws_instance.posthog` + SG + `e.` A-record, modeled
> on `aws_instance.db` in `terraform/production/database.tf`). Decide sizing
> first, then add it.

---

## 2. Secrets — create/verify in Secrets Manager

`terraform/production/secrets.tf` declares **`packiot/production/posthog`** with
terraform-generated values:

```json
{
  "secret":                    "<django SECRET_KEY, 50 chars>",
  "postgres_user":             "posthog",
  "postgres_db":               "posthog",
  "postgres_password":         "<32 chars>",
  "object_storage_access_key": "object_storage_root_user",
  "object_storage_secret_key": "<32 chars>"
}
```

- `terraform apply` in `terraform/production/` creates it (like the other
  `packiot/production/*` secrets). `ignore_changes = [secret_string]` means a
  later manual rotation won't be clobbered.
- The **`secret` (Django SECRET_KEY) must never change** once PostHog has data —
  rotating it invalidates sessions and any encrypted fields.
- These are **separate** from the OEE DB/redis — PostHog gets its own PG + minio
  creds; nothing is shared with the r7g or app-redis.

How they reach `.env` on the PostHog box: `app_init.sh` has a commented
codification block (the ONBOARD_API_KEY / OAUTH2_PROXY_* precedent). At bring-up
run it once (see §5) — it fetches the secret and appends `POSTHOG_*` to the box's
`.env`. On a dedicated box, run the same snippet there.

---

## 3. DNS + TLS for `e.prod.packiot.app`

**Do NOT apply DNS in this PR.** At bring-up, add the record:

- **Record:** `e.prod.packiot.app` → **A** → the PostHog box's **EIP**
  (dedicated box) **or** the app box EIP (co-locate).
  - Model it on `aws_route53_record.ingest` in
    `terraform/production/dns.tf` — a **direct A → EIP**, *not* a CloudFront
    ALIAS. Capture traffic must bypass CloudFront/WAF (high-volume POSTs, no
    caching, WAF body limits would drop session-recording payloads).
- **TLS:** `e.prod.packiot.app` is under the existing `*.prod.packiot.app`
  wildcard cert that `nginx_setup.sh`'s certbot already obtains — **no new cert**.
  - On a **dedicated** box, that box needs its own copy of the wildcard cert:
    run the same `certbot certonly --dns-route53 --domain '*.prod.packiot.app'`
    step there (the box's IAM role needs `route53:ChangeResourceRecordSets`), or
    obtain a single-name cert for `e.prod.packiot.app` via DNS-01.

**Apex alternative (`e.packiot.app`):** stronger ad-blocker dodge but NOT under
the wildcard — needs its own cert (like `dash.packiot.app`'s hand-managed HTTP-01
cert) + a record in the parent `packiot.app` zone. Chose `e.prod.packiot.app` to
stay under the wildcard and match every other vhost. `e.prod.packiot.app` is
still first-party, so it already dodges `*.posthog.com` / `i.posthog.com`
blocklists.

---

## 4. The reverse-proxy vhost

`nginx_setup.sh` writes `/etc/nginx/conf.d/posthog.conf` for `e.<domain>`, but
**only when the sentinel `/opt/packiot/posthog.enabled` exists** (so a routine
app-box boot doesn't get a spurious/502 vhost). Properties:

- **No oauth2 forward-auth, no origin-verify** — it's a public capture
  front-door for anonymous browser beacons (unlike every staff/operator vhost).
- **`client_max_body_size 64m`** — session-recording payloads are large.
- Single `location /` proxy → passes through **all** PostHog paths: UI `/`,
  assets `/static/`, ingestion `/e/ /s/ /i/ /decide/ /array/ /flags/ /batch/
  /capture/ /report/`.
- **CORS** scoped to the front/operator/dash SPA origins (browsers preflight
  `/decide/`); websocket upgrade headers passed (toolbar/heatmap).
- **Upstream:** `http://127.0.0.1:8000` (co-locate). **Dedicated box:** edit the
  block to `proxy_pass http://<posthog-box-private-ip>:8000;` and open the SG
  path app-box → PostHog:8000.

Enable it (after PostHog is up + DNS points here):

```bash
sudo touch /opt/packiot/posthog.enabled
sudo bash /tmp/nginx_setup.sh          # re-run standalone; writes + reloads the vhost
```

---

## 5. Deliberate bring-up sequence

On the **PostHog box** (dedicated, recommended — or the app box for co-locate):

```bash
# 5.1 — Materialize PostHog secrets into .env (app_init.sh codification snippet):
SEC=$(aws secretsmanager get-secret-value --secret-id packiot/production/posthog \
      --region us-east-1 --query SecretString --output text)
{
  echo "POSTHOG_APP_TAG=release-1.43.0"
  echo "POSTHOG_SITE_URL=https://e.prod.packiot.app"
  echo "POSTHOG_SECRET=$(echo "$SEC" | jq -r '.secret')"
  echo "POSTHOG_POSTGRES_USER=$(echo "$SEC" | jq -r '.postgres_user')"
  echo "POSTHOG_POSTGRES_DB=$(echo "$SEC" | jq -r '.postgres_db')"
  echo "POSTHOG_POSTGRES_PASSWORD=$(echo "$SEC" | jq -r '.postgres_password')"
  echo "POSTHOG_OBJECT_STORAGE_ACCESS_KEY_ID=$(echo "$SEC" | jq -r '.object_storage_access_key')"
  echo "POSTHOG_OBJECT_STORAGE_SECRET_ACCESS_KEY=$(echo "$SEC" | jq -r '.object_storage_secret_key')"
} >> /opt/packiot/.env         # or a dedicated /opt/posthog/.env you pass via --env-file

# 5.2 — Clone the pinned PostHog repo next to compose.posthog.yml (ClickHouse
#        mounts config/schema/idl from it — see compose header).
cd /opt/packiot/stack          # dir holding compose.posthog.yml
git clone --branch release-1.43.0 --depth 1 https://github.com/PostHog/posthog.git posthog

# 5.3 — Run DB + ClickHouse migrations, then bring the graph up (profile REQUIRED).
docker compose -f compose.posthog.yml --profile posthog up -d migrate
docker compose -f compose.posthog.yml --profile posthog logs -f migrate   # wait for exit 0
docker compose -f compose.posthog.yml --profile posthog up -d

# 5.4 — (optional) verify async migrations are complete:
docker compose -f compose.posthog.yml --profile posthog run --rm asyncmigrationscheck

# 5.5 — Point DNS (§3), then enable the capture vhost (§4):
sudo touch /opt/packiot/posthog.enabled && sudo bash /tmp/nginx_setup.sh

# 5.6 — Smoke test:
curl -sf https://e.prod.packiot.app/_health && echo OK
```

Then in the PostHog UI (`https://e.prod.packiot.app`):

1. Create the first **admin user** + **organization** + **project** (the initial
   sign-up flow; lock down further sign-ups afterward under Org settings).
2. Copy the **Project API key** (`phc_...`).
3. Set front4's **Amplify** env vars and redeploy front4:
   - `VITE_POSTHOG_KEY=phc_...`
   - `VITE_POSTHOG_HOST=https://e.prod.packiot.app`

---

## 6. Backup / retention (do NOT skip — these grow fast)

- **ClickHouse** (`posthog-clickhouse-data`): the event store; largest + most
  valuable. Back up with `clickhouse-backup` (or `BACKUP DATABASE posthog TO
  Disk('...')`) to S3 on a schedule; snapshot the EBS volume via AWS Backup like
  the OEE DB (`terraform/production/backups.tf` is the model). Set event TTLs in
  PostHog (Project → Data management) to cap growth.
- **minio / session recordings** (`posthog-object-storage`): recordings balloon
  fastest. Set a **retention** in PostHog (session-recording retention, e.g.
  30–90 days) AND a minio bucket lifecycle rule to expire old blobs. Snapshot the
  volume for DR.
- **Postgres** (`posthog-postgres-data`): metadata (projects, dashboards, flags).
  Small but essential — `pg_dump` on a schedule + EBS snapshot.
- **Kafka** (`posthog-kafka-data`): transient transport (24h retention set in
  compose) — no backup needed; ClickHouse is the durable store.

---

## 7. Rollback / teardown

```bash
# Stop PostHog (keeps data volumes):
docker compose -f compose.posthog.yml --profile posthog down

# Disable + remove the capture vhost:
sudo rm -f /opt/packiot/posthog.enabled /etc/nginx/conf.d/posthog.conf
sudo nginx -t && sudo nginx -s reload

# Point front4 away: unset VITE_POSTHOG_KEY / VITE_POSTHOG_HOST in Amplify + redeploy.
# Remove the e.prod.packiot.app DNS record.

# FULL teardown (DESTROYS analytics data — take backups first):
docker compose -f compose.posthog.yml --profile posthog down -v
```

Because PostHog runs as its **own compose project (`posthog`) on its own
network**, none of the above touches the OEE `stack` project. The default
`docker compose -f compose.production.yml up -d` is completely unaffected by any
PostHog state.

---

## 8. What the user must do at bring-up (checklist)

- [ ] **Decide sizing** — dedicated box (recommended) vs co-locate (§1). If
      dedicated: provision the EC2 + SG (terraform follow-up modeled on
      `aws_instance.db`).
- [ ] `terraform apply` so `packiot/production/posthog` exists (§2).
- [ ] Materialize `POSTHOG_*` into the PostHog box `.env` (§5.1).
- [ ] Clone `posthog@release-1.43.0` next to the compose (§5.2).
- [ ] `docker compose -f compose.posthog.yml --profile posthog up -d` after
      migrations (§5.3).
- [ ] Add **DNS** `e.prod.packiot.app` A → EIP (direct, not CloudFront) (§3).
- [ ] Ensure the **wildcard cert** is present on the box (§3).
- [ ] `touch /opt/packiot/posthog.enabled` + re-run `nginx_setup.sh` (§4).
- [ ] Create project → copy **API key** → set front4 Amplify
      `VITE_POSTHOG_KEY` + `VITE_POSTHOG_HOST` + redeploy (§5).
- [ ] Configure **ClickHouse + minio retention/backup** (§6).
