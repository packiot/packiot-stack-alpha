# Onboarding a new tenant — operator runbook

**Audience**: CS Admin engineers + on-call operators.
**When you read this**: when a new client (factory) is being onboarded
into the staging or production environment and their data needs to
flow through `oeecloud-worker`.

> **Status (2026-06-24, Strategy C Phase 1)**: per-tenant queues are
> declared at worker startup based on `packml_register`. The legacy
> queue still receives all current traffic. Until Phase 2 ships,
> per-tenant queues exist but are empty — onboarding still produces
> a working system without the cutover. After Phase 2 lands (separate
> change), the worker restart step becomes a hard precondition for the
> tenant's data to reach the DB.

> **UPDATE (Strategy D)**: the worker now **re-discovers tenants
> periodically** (every `TENANT_DISCOVERY_INTERVAL_SECONDS`, default 60) —
> not only at boot. A new `packml_register` client is picked up, its queues
> declared, and consumption started **with no restart** and no disruption to
> tenants already flowing. Step 2 below (restart) is therefore **optional** —
> use it only to pick a tenant up immediately instead of waiting one interval.
> See [[strategy-d-shared-pool-sac|Strategy D — shared pool + SAC]].

---

## TL;DR

1. CS Admin creates `enterprise → site → area → equipments → packml_register` rows (existing flow, no change).
2. **Restart `oeecloud-worker` on staging app EC2**. Worker auto-discovers the new tenant from `packml_register` at startup and declares queues.
3. Verify the new tenant's three queues exist on RabbitMQ.
4. Confirm the dashboard's `$tenant` variable now lists the new tenant.

That's it. The new step (#2) is the only thing different from pre-Strategy-C onboarding.

---

## Pre-flight checks (do these once, then forget)

Before onboarding **any** new tenant, verify the broker is set up correctly. These checks are one-time per environment.

### 1. RabbitMQ user permissions

```bash
sudo docker exec stack-rabbitmq-1 rabbitmqctl list_user_permissions oeecloud-worker
```

Expected output:

```
vhost  configure                                       write                                           read
/      ^(oee|oee-retry|oee-failed|oeecloud-worker-q.*)$  ^(oee|oee-retry|oee-failed|oeecloud-worker-q.*)$  ^(oee|oee-retry|oee-failed|oeecloud-worker-q.*)$
```

If the patterns are narrower (e.g. listing specific queue names instead of the `.*` regex), update them:

```bash
sudo docker exec stack-rabbitmq-1 rabbitmqctl set_permissions -p / oeecloud-worker \
  '^(oee|oee-retry|oee-failed|oeecloud-worker-q.*)$' \
  '^(oee|oee-retry|oee-failed|oeecloud-worker-q.*)$' \
  '^(oee|oee-retry|oee-failed|oeecloud-worker-q.*)$'
```

**Why this matters**: when declaring a new queue with `x-dead-letter-exchange`, RabbitMQ requires WRITE permission on the DLX target exchange (`oee-retry` and `oee` for our retry chain). The legacy queue dodges this check because it already exists; brand-new tenant queues hit it on first declaration. If perms are too narrow, the worker logs `ACCESS_REFUSED - write access to exchange 'oee-retry' refused` and retries indefinitely.

### 2. Worker can reach the DB

`oeecloud-worker` queries `packml_register` at startup. If DB is unreachable, worker fails to start (retry with backoff up to 5 minutes, then crash → Docker restarts).

```bash
sudo docker logs --tail 50 oeecloud-worker | grep -E "(secrets fetched|tenants discovered|tenant discovery failed)"
```

You should see something like:

```
{"msg":"secrets fetched", ...}
{"msg":"tenants discovered from packml_register","count":3,"tenants":["cpack","simcorp","staging"]}
```

If you see `tenant discovery failed`, fix the DB connectivity first.

---

## The onboarding sequence

### Step 1 — CS Admin creates the DB rows

This is the existing onboarding flow (per the project CLAUDE.md):

1. Enterprise (auto-generates `api_key` via `randomUUID()`)
2. Site
3. Area
4. Equipment (including `lead_machine`, `tp_equipment`, `id_unit`, `status_type`)
5. Shifts + Shift Hours
6. `packml_register` rows — **critical** for tenant discovery:
   - Set `active = true`
   - Set `packml_topic` to the Sparkplug topic (e.g. `ACME/SC/LINE-01/MACHINE-A/Status/StateCurrent`)
   - The first `/`-separated segment is the `group_id` that becomes the tenant identifier

The lowercased `group_id` (e.g. `acme`) is what the worker will use as the tenant ID.

### Step 2 — Restart oeecloud-worker

Worker auto-discovery runs **at startup only** (Phase 1 design — dynamic discovery is deferred). After CS Admin commits the new `packml_register` rows, restart the worker:

```bash
sudo docker restart oeecloud-worker
```

Alternatively via SSM from your workstation:

```bash
aws ssm send-command --instance-ids i-06c9547a2c7091ab7 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo docker restart oeecloud-worker"]'
```

Restart takes ~10 seconds (Go binary, fast startup). The worker will:

1. Connect to RabbitMQ + DB
2. Query `packml_register` for active group_ids → finds your new tenant
3. Declare three queues for each tenant: `<prefix>-<tenant>`, `<prefix>-<tenant>-retry-30s`, `<prefix>-<tenant>-failed`
4. Resume consuming the legacy queue (Phase 1) — your new tenant's queues are EMPTY until Phase 2

### Step 3 — Verify queue declarations

```bash
sudo docker exec stack-rabbitmq-1 rabbitmqctl list_queues -p / name messages \
  | grep oeecloud-worker-q-<new-tenant>
```

Expected:

```
oeecloud-worker-q-acme           0
oeecloud-worker-q-acme-failed    0
oeecloud-worker-q-acme-retry-30s 0
```

Three queues, all empty (no traffic until Phase 2). If you see fewer than three, check worker logs for declaration errors.

### Step 4 — Confirm Grafana picks up the new tenant

Open `https://grafana.staging.packiot.app/d/oeecloud-worker`. The `$tenant` dropdown at the top should now list your new tenant. It'll show 0 throughput today; that's expected until Phase 2.

Alternatively, query Prometheus directly:

```bash
curl -sGf http://172.18.0.22:9090/api/v1/label/tenant/values | jq .data
```

Note: Prometheus updates label values during scrape, not from DB. So the new tenant only appears in the values list **once it has actual metric data**. Today that requires Phase 2 traffic flowing OR a temporary publish via rabbitmq-publish tool. Without traffic, the tenant queue exists but the dashboard's `$tenant` dropdown only sees it after the first scrape with that label.

---

## Troubleshooting — three known failure modes

### Failure 1 — `ACCESS_REFUSED - write access to exchange 'oee-retry'`

**Symptom**: worker logs show:
```
amqp connection failed, retrying
  err: topology: declare tenant queue oeecloud-worker-q-<X>:
       Exception (403) ACCESS_REFUSED - write access to exchange 'oee-retry' ...
```

**Root cause**: RabbitMQ user `oeecloud-worker` doesn't have WRITE permission on `oee-retry` (the DLX target exchange specified in the queue declaration's `x-dead-letter-exchange` argument).

**Fix**: see Pre-flight check #1. The write pattern must include `oee` and `oee-retry`. Apply the broader pattern, then the worker's next retry-reconnect cycle (within ~30s max backoff) will succeed.

### Failure 2 — config file changes don't take effect after deploy

**Symptom**: you edited `monitoring/prometheus/prometheus.yml` or `grafana/provisioning/datasources/*.yml`, the deploy ran successfully, but the running container still uses the old config.

**Root cause**: Docker **file** bind mounts (as opposed to directory mounts) bind to the source file's **inode**, not its path. Git checkout typically replaces the file (write-temp-then-rename for atomicity), which assigns a new inode. The running container is still pinned to the old inode and reads stale content.

**Fix**: the long-term fix is `labels.config_rev` (Prometheus) or `labels.provisioning_rev` (Grafana) on the compose service block. Bump the label string whenever the config changes; `docker compose up -d` then recreates the container, which re-binds to the current inode. For an immediate fix on a running system:

```bash
sudo docker restart prometheus    # or stack-grafana-1
```

This destroys and re-creates the container, picking up the current file content.

### Failure 3 — new tenant onboarded but worker didn't pick it up

**Symptom**: CS Admin added `packml_register` rows for `acme` (active=true), but `oeecloud-worker-q-acme` doesn't exist on the broker.

**Root cause**: under Strategy D, tenant discovery re-runs every
`TENANT_DISCOVERY_INTERVAL_SECONDS` (default 60), so a new tenant should appear
within ~1 minute. If it doesn't: (a) the interval is set to `0` (boot-only mode)
— restart the worker or raise the interval; (b) `LEGACY_INGEST_ENABLED=false`
leaves the discoverer unwired (per-tenant consumption disabled); or (c) the
`packml_register` rows aren't `active=true` / the `packml_topic` group_id
segment is malformed.

**Fix**: confirm the tick is running via
`docker logs oeecloud-worker | grep -E "dynamic tenant discovery|dynamically onboarded"`.
You should see `dynamic tenant discovery active` at connect and
`dynamically onboarded tenant` when your tenant is picked up. A restart still
works as an immediate pickup.

---

## What changes in Phase 2 (future)

After Phase 2 (edge-nodered publisher cutover) ships:

- edge-nodered will publish with `routing_key = sparkplug.data.<group_id>` instead of the flat `sparkplug.data`.
- The legacy `oeecloud-worker-q` queue's `#` binding will be removed from the source exchange — it stops receiving new traffic.
- Per-tenant queues will start receiving messages.
- The worker will consume per-tenant queues (currently consumes legacy only).
- **At that point, restarting the worker after onboarding becomes load-bearing**: forgetting it means the new tenant's traffic goes to the **catch-all** queue (once that ships via Alternate Exchange), or is dropped silently (if catch-all doesn't ship).

For now (Phase 1), forgetting the restart is harmless — the legacy queue absorbs everything regardless of which tenants the worker knows about.

---

## References

- [[strategy-c-per-tenant-queues|Strategy C design doc]] — the full topology + migration plan
- [[strategy-a-worker-pool|Strategy A design doc]] — sibling design that composes with C
- Worker source: `services/oeecloud-worker/internal/tenants/discovery.go`
- Project CLAUDE.md — the CS Admin onboarding sequence (existing flow)
- AWS SSM connect: `aws ssm start-session --target i-06c9547a2c7091ab7 --region us-east-1`
