---
title: Runbooks
layer: 4
owner_area: platform
last_verified: 2026-09-28
---
# Runbooks

> **Layer 4 · Operations** — an index of every runbook in the repository with its purpose,
> followed by the ten most common staging operations as exact, safe commands. For on-call
> engineers. Up: [Platform & operations](../subsystems/platform.md)

!!! warning "Before you run anything"
    - Staging carries **real client data** (CPACK co-tee, Bispharma live box). Treat it with
      production care. Anything touching new-stack production or the legacy DB needs explicit
      sign-off; the legacy DB is **read-only** for us.
    - An approval is for the state it was given in. If time has passed, re-check before acting
      (2026-09-25: a host was rebooted hours after it had already recovered).
    - Read before you write: every SQL below that changes data says so; run the `SELECT` first
      and take a backup table (`CREATE TABLE ops._bkp_<what>_<date> AS …`) for bulk changes.

## Runbook index

| Runbook | Purpose |
|---|---|
| `terraform/staging/EDGE-PROTECTION-RUNBOOK.md` | staged CloudFront + WAF + ACM rollout for staging (cutover and origin lock flags) |
| `terraform/production/EDGE-PROTECTION-RUNBOOK.md` | same for new-stack production (adds the `dash.packiot.app` SAN) |
| `docs/runbooks/oauth2-proxy-cognito-migration.md` | replace Authentik with oauth2-proxy + Cognito for staff gates (ADR-0034 §C) |
| `docs/superset-golive-runbook.md` | bring the Superset overlay live on staging (secrets, profile, RLS gate, embed) |
| `docs/ci-selfhosted-runner-runbook.md` | register the org CI runner (`packiot-ci`) and wire repos to it |
| `docs/guides/backup-restore-runbook.md` | DB backup decision memo and point-in-time-restore drill |
| `terraform/staging/scripts/backup-db.sh`, `restore-db.sh` | DB-host dump to S3 and restore (driven by `packiot-db-backup.timer`) |
| `docs/ingestion/cpack-tee-golive-runbook.md` | swap staging's synthetic CPACK source for the real CPACK Mode-A tee (ADR-0042 P1) |
| `docs/clients/cpack-controlled-edge-deploy-runbook.md` | deploy a parallel Node-RED + sparkplug-agent at the CPACK site (read-only co-tee) |
| `docs/clients/cpack-newprod-seed-runbook.md` | seed CPACK ready-but-empty on new-stack production |
| `docs/clients/bispharma-prod-recut-runbook.md` | Bispharma production go-live execution (re-cut) |
| `docs/clients/bispharma-twin-convergence-runbook.md` | planned maintenance to converge the Bispharma feed onto the codified twin (not under live feed) |
| `docs/adr/reference/0016-flip-runbook.md` | the single-flow consolidation flip (ADR-0016 §6) |
| `docs/adr/reference/production-recut-runbook.md` | re-cut `production` from `staging` with the prod overlay — design only, needs user sign-off |
| `docs/ops/rabbitmq-topology.md` | canonical queue set per tenant and how to remove orphan queues safely |
| `docs/ops/observability-persona-dashboards.md` | which Grafana board answers which question |
| `docs/ops/aws-cost-optimization.md` | AWS cost audit and tracker (read-only) |
| `docs/ops/worker-tier-k8s-orchestration.md` | design for scaling the worker tier (not an operating procedure) |
| `docs/wiki-deploy.md` | wiki bucket/role/cron wiring (see [wiki pipeline](../components/wiki-pipeline.md)) |
| `services/historian-gateway/README.md` | historian gateway start, hardening and recreate |
| `scripts/deploy-db-agent.sh` | (re)deploy the DB-box Alloy agent via SSM |
| `scripts/provision-sandbox-tenant.sh` | provision or `--heal` the sandbox tenant 2000003 |
| `scripts/ops/refill-shift-history.sh`, `scripts/ops/repair-truncated-stops.sh` | targeted data repairs (read the script header first) |
| `scripts/scalability-probe.sh` | capacity probe of broker, workers and DB |

Older narrative guides with operational content: `docs/wiki/13-dba-guide.md` (superseded by
[DBA guide](dba-guide.md)), `docs/guide/08-observability.md`.

## Top 10 tasks

The ten tasks:

1. [SSM access to a host](#ssm-access-to-a-host)
2. [Check the stack is up](#check-the-stack-is-up)
3. [Redeploy](#redeploy)
4. [Recreate a single service](#recreate-a-single-service) from its compose labels
5. [Read logs](#read-logs)
6. [Check DB health](#check-db-health)
7. [Drain a dead-letter queue](#drain-a-dead-letter-queue)
8. [Restart the rollup safely](#restart-the-rollup-safely)
9. [Verify freshness](#verify-freshness)
10. [Publish the wiki](#publish-the-wiki)

Plus: [free disk on the app host](#extra-free-disk-on-the-app-host).

Conventions below: `APP=<staging app instance id>` and `DB=<staging DB instance id>`. Find
them without guessing:

```bash
aws ec2 describe-instances --region us-east-1 \
  --filters Name=tag:Name,Values=packiot-staging-app,packiot-staging-db \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name]' --output table
```

### SSM access to a host

```bash
aws ssm start-session --region us-east-1 --target "$APP"
sudo -i                       # ssm-user is not in the docker group
cd /opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha   # the deploy checkout
```

There are no shared SSH keys. For a web UI on the host (Prometheus, RabbitMQ management),
port-forward instead of opening ports:

```bash
aws ssm start-session --target "$APP" --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["15672"],"localPortNumber":["15672"]}'
```

Non-interactive `aws ssm send-command` may be denied for your identity on some hosts; the
2026-07-22 DB-access notes used `AWS-StartNonInteractiveCommand` sessions instead. The legacy
DB secret (`databaseCredentials`) is readable only from the **app** host's role.

### Check the stack is up

```bash
# from a laptop: the public edge (CloudFront → nginx → containers)
for h in operator grafana csadmin customize; do
  printf '%-10s ' "$h"; curl -s -o /dev/null -w '%{http_code}\n' "https://$h.staging.packiot.app/"; done
# on the app host: anything not running/healthy?
docker ps -a --format '{{.Names}}\t{{.Status}}' | grep -vE 'Up .*\(healthy\)|Up [0-9]+ (seconds|minutes|hours|days|weeks)$'
docker compose -p stack -f compose.staging.yml -f compose.superset.yml ps -a --format 'table {{.Service}}\t{{.State}}\t{{.Health}}'
```

Then Grafana **Overview** (`audience/00-overview`) for firing alerts and "does data land".
A 200 from the edge (or 302 to the sign-in page for gated hosts) is the real "stack up" signal.

### Redeploy

Whole stack, current `staging` HEAD:

```bash
gh workflow run deploy-staging.yml --ref staging
gh run list --workflow deploy-staging.yml --limit 3
```

If you just merged, wait a few minutes first: push events can reach Actions late, and a manual
dispatch on top queues a second full deploy. Never build or `up` on the host under a project
name other than `stack`.

### Recreate a single service

Use the container's own compose labels so you reproduce exactly how it was created (project,
working directory, compose files):

```bash
C=stream-engine    # container name
P=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$C")
S=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$C")
WD=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$C")
CF=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$C")
echo "project=$P service=$S dir=$WD files=$CF"          # read it before running
cd "$WD" && docker compose -p "$P" $(printf -- '-f %s ' ${CF//,/ }) up -d --no-deps --force-recreate "$S"
```

- `--no-deps` avoids touching dependencies; `--force-recreate` is needed when only `.env` or a
  mounted file changed (compose does not diff file contents).
- `docker restart <c>` keeps the **creation-time** environment; to apply a changed `.env`
  you must recreate.
- The historian gateway also needs its env file:
  `--env-file /opt/packiot/.env.historian-gateway` (see
  [historian gateway](../components/historian-gateway.md)).
- A recreate is not permanent if the change is not in git: the next deploy renders the
  committed compose file.

### Read logs

```bash
docker logs --since 30m --tail 200 stream-engine            # pinned container names
docker logs --since 30m stack-rabbitmq-1                    # unpinned: stack-<svc>-1
docker logs --since 1h sparkplug-decoder 2>&1 | grep -iE 'error|warn|timeout'
journalctl -u historian-staging-append --since today        # host timers (not containers)
```

In Grafana use Explore → Loki with `{service="stream-engine"} |= "TIMED OUT"`. Loki keeps 72 h
and does not contain `hist-gateway` logs (different compose project).

### Check DB health

On the DB host (`aws ssm start-session --target "$DB"`, then `sudo -i`):

```bash
docker exec timescaledb pg_isready -U postgres
docker exec timescaledb psql -U postgres -d packiot_analytics -c "
  SELECT count(*) AS conns, count(*) FILTER (WHERE state='active') AS active,
         count(*) FILTER (WHERE state='idle in transaction') AS idle_in_tx,
         current_setting('max_connections') AS max
  FROM pg_stat_activity;"
docker exec timescaledb psql -U postgres -d packiot_analytics -c "
  SELECT pid, application_name, state, now()-xact_start AS tx_age, left(query,80)
  FROM pg_stat_activity WHERE state <> 'idle' ORDER BY xact_start NULLS LAST LIMIT 15;"
docker exec timescaledb psql -U postgres -d packiot_analytics -c "
  SELECT job_id, proc_name, last_run_status, last_successful_finish, total_failures
  FROM timescaledb_information.job_stats j JOIN timescaledb_information.jobs USING (job_id)
  WHERE last_run_status <> 'Success' OR total_failures > 0;"
df -h /
```

From the app host (credentials from `.env`, never echoed):

```bash
set -a; . /opt/packiot/.env; set +a
docker run --rm --network stack_packiot-net -e PGPASSWORD="$POSTGRES_PASSWORD" postgres:16-alpine \
  psql -h "$POSTGRES_HOST" -U "$POSTGRES_USER" -d packiot_analytics -c 'SELECT now(), version();'
```

Alerts that matter: `PostgresDown`, `PostgresConnectionsHigh` (>160 of 200),
`AnalyticsCaggRefreshLag`, `AnalyticsTimescaleJobFailing`. Deeper: [DBA guide](dba-guide.md).

### Drain a dead-letter queue

Fix the cause first; replaying poison messages just refills the queue.

**RabbitMQ `-failed` queues and `oee-unroutable-q`** (inspect only):

```bash
docker exec stack-rabbitmq-1 rabbitmqctl list_queues name messages consumers \
  | grep -E 'failed|unroutable' | awk '$2>0'
```

Look at a sample in the management UI (port-forward 15672, queue → Get messages, "Nack
message requeue true"). `oee-unroutable-q` filling means a tenant publishes to a routing key
no queue binds: add the tenant to `WORKER_TENANT_ALLOWLIST` (see
`docs/ops/rabbitmq-topology.md`).

!!! warning "Unverified: replaying RabbitMQ DLQs"
    The broker has only the `management` and `prometheus` plugins enabled; there is no
    committed replay (shovel) procedure. Do not enable plugins on the live broker ad hoc — a
    plugin change once recreated it and lost users (2026-07-10). Agree a replay plan first.

**Legacy-replicator DLQ** (`ops.mirror_replay_dlq` in `packiot_analytics`):

```sql
SELECT source, count(*) AS rows, max(retry_attempts) AS max_attempts, min(created_at), max(created_at)
FROM ops.mirror_replay_dlq GROUP BY source;
-- after the root cause is fixed: WRITE — re-arm exhausted rows so the retrier re-drives them
UPDATE ops.mirror_replay_dlq SET retry_attempts = 0 WHERE source = 'legacy-cpack';
```

The retrier re-dispatches through the same idempotent handlers and deletes rows on success
(`services/analytics-sync/internal/replicate/dlq.go`). This drained 1,374 rows to 0 on
2026-09-20 after the overlap-guard fix (#1335).

### Restart the rollup safely

The rollups are ticks inside `stream-engine`; each tick is its own transaction, so a restart
loses at most the in-flight tick.

```bash
# 1. is a tick timing out or erroring?
docker logs --since 30m stream-engine 2>&1 | grep -E 'runtime-rollup|TIMED OUT|failed' | tail -20
# 2. is something holding locks? (DB host)
docker exec timescaledb psql -U postgres -d packiot_analytics -c "
  SELECT pid, application_name, now()-xact_start AS age, left(query,80)
  FROM pg_stat_activity WHERE state='idle in transaction' AND now()-xact_start > interval '5 min';"
# 3. restart (same env) — or recreate (task 4) if env changed
docker restart stream-engine
docker inspect -f '{{.State.Health.Status}}' stream-engine
```

- An old `idle in transaction` session from stream-engine blocked shift ticks for 15 minutes
  on 2026-09-25; `SELECT pg_terminate_backend(<pid>)` for **that** pid only.
- If shift ticks time out (`job tick TIMED OUT timeout=300s`), the lever is
  `ROLLUP_SHIFT_LIMIT` in `compose.staging.yml` (75 since 2026-09-22), changed by PR — see
  [stream-engine rollup internals](../components/stream-engine-rollup-internals.md).
- Backlogs drain **oldest first**; the current shift can starve behind old dirty rows.

### Verify freshness

```sql
-- raw landing per tenant (analytics DB)
SELECT id_enterprise, max(ts_value) AS last_value, now() - max(ts_value) AS lag
FROM silver.equipment_values WHERE ts_value > now() - interval '1 day'
GROUP BY id_enterprise ORDER BY id_enterprise;
-- current-shift gold rows that are dirty or never computed
SELECT count(*) AS rows,
       count(*) FILTER (WHERE recalc_needed) AS dirty,
       count(*) FILTER (WHERE computed_at IS NULL) AS never_computed,
       max(computed_at) AS last_write
FROM gold.equipment_oee_shift WHERE ts_value <= now() AND ts_end > now();
```

Fresh `silver` but stale current-shift gold ⇒ the shift rollup is stalled, not the data
(2026-09-22). Also check the `aud-cs` board and the `ClientIngestStopped` alert per tenant.
Historian freshness: `scripts/historian-staleness-monitor.sh` (run daily by
`historian-integrity-monitor.timer` at 04:00 UTC).

### Extra: free disk on the app host

```bash
df -h /
docker system df
docker builder prune -f --keep-storage 5GB    # the usual culprit; safe
docker image prune -f                          # dangling images only
```

Never `docker volume prune` (outbox, broker and metrics volumes live there) and never
`docker system prune -a` on the shared host. Deploys already prune the build cache.

### Publish the wiki

```bash
scripts/build-wiki.sh && python3 -m http.server -d dist/wiki 8000   # preview locally
# merge the docs PR into staging → build-wiki.yml builds and syncs to S3
gh workflow run build-wiki.yml --ref staging                        # or force a rebuild
```

The serving box pulls from S3 every 5 minutes. Details: [wiki pipeline](../components/wiki-pipeline.md).

## Related

- [Platform & operations](../subsystems/platform.md) · [CI/CD](../components/ci-cd.md) ·
  [Compose topology](../components/compose-topology.md) · [Observability](../components/observability.md)
- [Environments](../architecture/environments.md) for hosts and URLs
