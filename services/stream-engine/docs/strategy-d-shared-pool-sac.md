# Strategy D — Shared Worker Pool + Dynamic Tenant Discovery

Builds directly on [[strategy-a-worker-pool|Strategy A]] (in-process concurrency)
and [[strategy-c-per-tenant-queues|Strategy C]] (per-tenant queues). Where A/C
kept ONE worker process that discovered tenants only at boot, Strategy D makes
the worker a **horizontally-scalable pool** with **live tenant discovery** — and
does it without breaking per-tenant OEE ordering.

> **Status:** implemented, DEFAULT-OFF for the scale/SAC parts. Dynamic
> discovery is on by default (additive, safe). Nothing about a single-instance
> deploy changes until you opt in.

---

## 1. The two problems

1. **Boot-only discovery.** `DiscoverActive` (`SELECT DISTINCT lower(split_part(
   packml_topic,'/',1)) FROM packml_register WHERE active=true`) ran once at
   boot. Onboarding a client meant restarting the worker, which briefly
   disrupts **every** tenant; until the restart, a new tenant's messages hit the
   `oee` topic exchange with **no matching binding** and are silently dropped.

2. **Single instance.** One process consumed all tenant queues. No horizontal
   scale, no failover. But you can't naively run two replicas: OEE counter
   processing is **order-sensitive** — increments are deltas differenced from a
   per-topic baseline held in process-local state. Two consumers on the same
   tenant's stream, processing out of order, corrupt the counts.

---

## 2. Design

### 2a. Dynamic discovery (default ON, additive)

A ticker in each connection cycle re-runs `DiscoverActive` every
`TENANT_DISCOVERY_INTERVAL_SECONDS` (default 60). Each tick reconciles the
live consumer set against the DB:

- **New tenant** → declare its queue-triple + binding (`DeclareTenant`, idempotent),
  register its routing-key handler, and start a consumer goroutine **on the
  existing connection** — no restart, no disruption to tenants already flowing.
- **Removed tenant** (`active=false`) → cancel just that tenant's consumer
  goroutine. Its queues are **left on the broker** (Strategy C §12.7 — never
  auto-delete; you'd lose in-flight messages).
- A discovery error (transient DB blip) is **non-fatal**: keep the current set,
  retry next tick. Never drain a live tenant on a failed lookup.

The authoritative tenant set is kept on the `Consumer` (mutex-guarded) and
updated as tenants come/go, so a **reconnect re-declares exactly what we
consume** — dynamically-added tenants survive a broker bounce.

`0` disables the loop entirely (boot-only, the pre-Strategy-D behavior).

### 2b. Horizontal scale via Single Active Consumer (default OFF)

RabbitMQ's [single-active-consumer](https://www.rabbitmq.com/consumers.html#single-active-consumer)
(SAC) is the key. Declare each per-tenant **main** queue with
`x-single-active-consumer: true`. Then:

- **Every replica subscribes to every tenant queue.** For each queue RabbitMQ
  keeps exactly **one active consumer** (gets all deliveries, in order); the
  rest are **hot standbys** that receive nothing until the active one drops.
- Different tenants' active consumers land on **different replicas**, so the
  fleet spreads load by tenant while each tenant stays strictly ordered.
- If the active replica dies, RabbitMQ **fails over** to a standby
  automatically. That failover is, from the worker's point of view, identical to
  a reconnect: the new active consumer starts reading the tenant's stream fresh.
  The counter baseline is process-local and **re-seeds on first observation**
  (the edge-transformer Calc's first-observation seeding), exactly as it does
  after any reconnect — so a mid-stream failover does not corrupt counts.

Only the **main** queue carries SAC. The `-retry-30s` and `-failed` queues have
no active consumer (retry is TTL→DLX, failed is human-inspection), so SAC is
meaningless there and is deliberately **not** set — leaving them byte-identical
and migration-free.

### 2c. Why SAC over the alternatives

| Alternative | Why rejected |
|---|---|
| Competing consumers (plain shared queue) | Round-robins a tenant's stream across replicas → out-of-order deltas → corrupted counters. The exact thing we must avoid. |
| Consistent-hash exchange (tenant→replica) | Static assignment; no automatic failover; rebalancing on scale needs a rebind dance. SAC gives failover + arbitration for free. |
| One container per tenant | N deploy surfaces, N metrics endpoints, no shared resolver/pool. Doesn't scale operationally with tenant count. |
| Leader election in-app (etcd/consul) | Reinvents what the broker already does correctly. New dependency, new failure mode. |

---

## 3. THE migration caveat — queue arguments are immutable

**Queue arguments cannot be changed after declaration.** An existing
`oeecloud-worker-q-<tenant>` declared without SAC **cannot** be redeclared with
`x-single-active-consumer` — RabbitMQ returns **406 PRECONDITION_FAILED** and
**closes the channel**. Left unhandled that would wedge the worker in a
declare→406→reconnect loop.

How this PR handles it (approach *(a)*: flag-gated + scripted migration):

1. **`WORKER_POOL_SAC_ENABLED` defaults false** → the arg is never set →
   existing queues declare byte-identically. **Existing deploys are unaffected.**
2. Each tenant triple is declared on its **own channel** (`DeclareTenant`), so a
   406 on one tenant can't poison the shared topology channel or other tenants.
3. On a 406 while SAC is enabled, `DeclareTenant` returns the typed
   `ErrSACMismatch` and logs a **loud remediation** pointing at the migration
   script — instead of an opaque channel death. **We never implicitly delete a
   queue.**

### Migration steps (one-time, per environment)

Run in a low-traffic window (deleting a queue drops any messages sitting in it;
ingest is at-least-once + idempotent + counter-re-seeding, so a brief absence
heals — but don't do it mid-backlog-drain):

```bash
# 1. Delete the old (non-SAC) MAIN queues. retry/failed are left intact.
RABBITMQ_CONTAINER=stack-rabbitmq-1 \
  services/oeecloud-worker/scripts/migrate-tenant-queues-sac.sh cpack acme foo
#    (omit the tenant list to auto-discover main queues from the broker)

# 2. Turn SAC on and scale the pool, then redeploy:
#    in .env →  WORKER_POOL_SAC_ENABLED=true
#               OEECLOUD_WORKER_REPLICAS=3
#    and comment out `container_name` + the static `ipv4_address` on the
#    oeecloud-worker service (both require uniqueness under N>1).

# 3. Verify:
#    - worker log `amqp topology declared` shows single_active_consumer=true
#    - rabbitmqctl list_queues name arguments | grep single-active-consumer
```

The worker recreates each main queue **with** the SAC arg on its next topology
declaration, so step 1 + redeploy is all it takes.

---

## 4. How to scale replicas

`docker compose up` (v2) honors `deploy.replicas`. The service block carries
`replicas: ${OEECLOUD_WORKER_REPLICAS:-1}` — **default 1, nothing changes**.

```bash
# after the SAC migration above:
OEECLOUD_WORKER_REPLICAS=3 docker compose -f compose.staging.yml up -d oeecloud-worker
# or set OEECLOUD_WORKER_REPLICAS in .env and redeploy normally.
```

**Two single-instance affordances must be removed for N>1** (they require
uniqueness): `container_name: oeecloud-worker` and the static
`ipv4_address: 172.18.0.20`. Both are commented as such in the compose file.
The worker **binds no host port** (health `:9101` is in-container only, probed
via the `--healthcheck` subcommand), so there is **no host-port collision** when
scaled. Prefer spreading replicas across app hosts in real deployments —
multiple replicas on one host give failover + tenant spread but share that
host's `cpus: 0.5` budget, so they don't add total throughput.

---

## 5. Instance-safety audit

Everything Strategy A already made concurrency-safe (RWMutex resolver, atomic
counters, stateless writers, thread-safe pgx pool + prometheus + slog) still
holds across **processes** because the state is per-process. The new shared
mutable surface is small:

| Surface | Under Strategy D | Safe? |
|---|---|---|
| `Dispatcher.handlers` map | discovery loop `Register`s a new tenant route while consumers `Handle` | ✅ now RWMutex-guarded |
| `Consumer.tenants` set | grown/shrunk by discovery, read on reconnect | ✅ `tenantsMu`-guarded |
| `consumed` map (per-connection) | boot loop + single discovery goroutine | ✅ `consumedMu`-guarded; effectively single-writer |
| per-topic counter baseline | process-local; **one active consumer per tenant** under SAC | ✅ ordering preserved; failover re-seeds like a reconnect |

The ordering guarantee rests entirely on SAC keeping **one active consumer per
tenant**. Without SAC (single instance, the default) there is trivially one
consumer. With SAC + N replicas, RabbitMQ enforces it.

---

## 6. What's unaffected

- **Retry/failed DLQ topology** — per-tenant `-retry-30s` (TTL→DLX→source) and
  `-failed` queues are unchanged and do **not** get SAC (no active consumer).
  The retry chain works identically whether the message is redelivered to the
  same or a different replica (idempotent handlers).
- **The legacy `oeecloud-worker-q`** (bare `sparkplug.data`) — still consumed for
  the whole connection lifetime, not per-tenant-cancelable, no SAC. Under a pool
  it would be consumed by every replica as competing consumers; if you keep the
  legacy leg AND scale, give it SAC too or retire it first. (In single-flow prod
  and post-10.9 staging the real traffic is per-tenant `sparkplug.data.<t>`.)
- **`LEGACY_INGEST_ENABLED=false`** path — the discoverer is left unwired, so the
  dynamic loop is inert and that path stays byte-identical.

---

## 7. New env / knobs (defaults preserve current behavior)

| Env | Default | Effect |
|---|---|---|
| `TENANT_DISCOVERY_INTERVAL_SECONDS` | `60` | Re-discovery cadence. `0` = boot-only. |
| `WORKER_POOL_SAC_ENABLED` | `false` | `x-single-active-consumer` on main tenant queues. Requires the queue migration. |
| `OEECLOUD_WORKER_REPLICAS` (compose) | `1` | `deploy.replicas` for the worker service. |

---

## 8. Rollout order

1. Ship this PR (all defaults preserve behavior). Dynamic discovery starts
   working immediately — onboarding no longer needs a restart.
2. When ready to scale: run `migrate-tenant-queues-sac.sh`, set
   `WORKER_POOL_SAC_ENABLED=true` + `OEECLOUD_WORKER_REPLICAS=N`, comment out
   `container_name`/static IP, redeploy.
3. Verify SAC active + tenant spread across replicas in the broker mgmt UI
   (each main queue shows N consumers, 1 active).

---

## 9. References

- `internal/amqp/topology.go` — `DeclareTopology(conn)` + `DeclareTenant` (SAC arg + 406 `ErrSACMismatch`)
- `internal/amqp/consumer.go` — `discoveryLoop` / `reconcileTenants` / per-tenant cancelable consumers
- `internal/handlers/dispatcher.go` — RWMutex-guarded Register/Handle
- `scripts/migrate-tenant-queues-sac.sh` — the one-time queue migration
- [[strategy-a-worker-pool|Strategy A]] · [[strategy-c-per-tenant-queues|Strategy C]]
- Industry parallel: SAC per-queue + fan-out-by-tenant is the AMQP shape of
  Kafka consumer-groups' per-partition single-consumer with partition rebalancing.
