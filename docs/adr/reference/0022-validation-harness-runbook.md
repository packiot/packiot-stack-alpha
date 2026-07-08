# ADR-0022 V1 — Validation Harness Runbook

Operational reference for the pre-flip behavior-validation harness. Read
[ADR-0022](../0022-pre-flip-behavior-correctness-validation.md) first for the
*why*; this doc is the *how*.

**What V1 stands up:** the refactored service stack (edge-transformer,
oeecloud-worker, refdata-api, mirror-worker-go, shadow-mirror) plus its
supporting infra (rabbitmq, pgbouncer, edge-api) against an **isolated**
database `packiot_validation`, driven by **real data from both tenants**:

| Tenant | id_enterprise | Data source | Path into packiot_validation |
|--------|---------------|-------------|------------------------------|
| CPACK | 3 | real prod (mirror) | `mirror-worker-go-val` reads prod (SELECT-only) → edge-api-val (PO lifecycle) + direct DB (values/events) |
| Incoplast | 4 | **real live SparkPlug B** | operator tee → `mosquitto-val` (8883 TLS) → `edge-transformer-val` → `rabbitmq-val` → `oeecloud-worker-val` → DB → OEE cascade |

**No emulator, no simulator.** V1 scope is only what Incoplast *shares* with
CPACK — the standard pipeline, OEE cascade, PO lifecycle, mirror pattern.
Incoplast's bespoke customizations (custom counters, ERP sync, operator→PLC
commands, its operator SPA) are **V2**.

---

## Isolation guarantees

The bake (`packiot_shadow`) and F1 (`packiot`) are **never touched**:

1. **Separate database.** Everything writes to `packiot_validation` only.
   `.github/workflows/deploy-validation.yml` has a guardrail step that hard-fails
   if the target name is anything but `packiot_validation`, and explicitly
   refuses `packiot` / `packiot_shadow`. The database NAME is forced by the
   workflow; only host/user/password are read from `/opt/packiot/.env`.
2. **Separate network.** `packiot-val-net` (172.19.0.0/24) — no shared subnet
   with staging's `packiot-net` (172.18.0.0/24).
3. **Separate compose project + names.** Deployed under `-p stackval`; every
   container is suffixed `-val`; every named volume is `*-val`. Verified: zero
   container-name / host-port / network-name collision with `compose.staging.yml`.
4. **Separate brokers.** `mosquitto-val` and `rabbitmq-val` are dedicated — no
   reuse of staging's `mosquitto` / `rabbitmq`, no queue/exchange collision.
5. **Independent mirror lineage.** `mirror-worker-go-val` uses
   `SOURCE_NAME=cpack-prod-val`, so its `mirror_replay_cursor` + `mirror_id_map`
   rows never touch staging's `cpack-prod-go` state.
6. **Prod creds stay in Secrets Manager.** `mirror-worker-go-val` is the only
   service that reads prod; it uses the SM secret `databaseCredentials`
   (SELECT-only) and deliberately does NOT set `CREDS_SOURCE=env`. Staging-tier
   services use `CREDS_SOURCE=env` (creds already in `.env`).

Host ports published by the val stack: `8883` (public, Incoplast tee),
`127.0.0.1:15673` (rabbitmq-val management), `127.0.0.1:8090` (edge-api-val).
None collide with staging.

---

## FILL AT DEPLOY — prerequisites before you run the workflow

These are secrets / host material NOT in git. Provision them on the **app EC2**
before deploying.

### 1. New Secrets Manager secret: `packiot/validation/db`

`mirror-worker-go-val` needs staging-tier DB creds whose **database name is
`packiot_validation`**. Create a secret identical to `packiot/staging/db` but
with `name` overridden:

```json
{
  "host": "10.10.10.89",        // FILL: staging DB EC2 private IP (same as packiot/staging/db)
  "port": 5432,
  "user": "postgres",           // FILL: same as packiot/staging/db
  "password": "<staging db pw>",// FILL: same as packiot/staging/db
  "name": "packiot_validation"
}
```

The EC2 IAM role already grants `packiot/staging/*`; confirm the resource ARN
pattern also covers `packiot/validation/db` (add it to the role policy if not).

### 2. mosquitto-val TLS material + password file

The external 8883 listener is **TLS + password-file** (never anonymous, never
1883 to the internet). Provision on the host at `/opt/packiot/mosquitto-val/`:

```bash
sudo mkdir -p /opt/packiot/mosquitto-val/certs

# Password file — one line per user; the tee client authenticates as 'incoplast'.
docker run --rm -i eclipse-mosquitto:2 \
  mosquitto_passwd -c -b /tmp/passwd incoplast '<CHOOSE-A-STRONG-PASSWORD>' \
  && docker cp ... # or run mosquitto_passwd locally; result → /opt/packiot/mosquitto-val/passwd

# TLS — a server cert/key for the broker's public hostname + the issuing CA.
#   /opt/packiot/mosquitto-val/certs/ca.crt      # FILL
#   /opt/packiot/mosquitto-val/certs/server.crt  # FILL (CN/SAN = the public host)
#   /opt/packiot/mosquitto-val/certs/server.key  # FILL (chmod 600)
```

Use a real (e.g. Let's Encrypt / internal CA) cert for the broker's public
hostname so the Incoplast `mqtt out` node can verify it. Ensure the EC2 security
group / nginx allows inbound 8883 from the Incoplast factory egress IP only.

### 3. rabbitmq-val user

`rabbitmq-val` boots with `${RABBITMQ_USER}` / `${RABBITMQ_PASSWORD}` from
`.env` (the same admin creds staging uses). `edge-transformer-val` and
`oeecloud-worker-val` authenticate with those same env creds via
`CREDS_SOURCE=env` — no new RMQ secret required.

---

## Deploy

```bash
# From the GitHub Actions UI (workflow_dispatch only):
#   Actions → "Deploy Validation Harness (ADR-0022 V1)" → Run workflow
#   confirm: validation
```

The workflow:
1. Guards the `confirm` input + asserts target DB == `packiot_validation`.
2. Inits the `edge-node-red` (db/) + `edge-api` submodules at their pinned commits.
3. Creates `packiot_validation` if absent (idempotent).
4. Applies `edge-node-red/db/*.sql` in sorted order (00-schema … 26-incoplast),
   with `ON_ERROR_STOP=1`; aborts if the CPACK (16) or Incoplast (26) fixtures
   are missing (wrong pin).
5. Sanity-checks both enterprises (3, 4) exist.
6. Builds + `up -d` the `stackval` project and waits for health.

**DO NOT** run `docker compose ... up` by hand as a substitute — the workflow's
guardrail + ordered seed is the reproducible path. Manual compose runs skip the
DB build entirely.

---

## Operator tee — the Incoplast side (hand this to the factory operator)

CPACK needs **no** node change (it is mirrored from prod). Incoplast needs a
one-time tee added to its **live** Node-RED.

Insert an `mqtt out` node in the live Incoplast Node-RED, wired to fire **after**
these existing nodes, republishing their SparkPlug B output:

- after `PackML2SparkPlug` / `prepare_Sparkplug & DBIRTH` → publish the **DBIRTH**
- after `SparkPlug DDATA` → publish the **DDATA**

**Order matters:** the transformer needs the DBIRTH alias table before it can
decode DDATA metric aliases. Tee **DBIRTH first, then DDATA**. Because the broker
retains NBIRTH/DBIRTH (persistence on), a reconnecting transformer recovers the
alias table from the retained DBIRTH — but the initial tee should still send
DBIRTH before DDATA starts flowing.

**Broker connection for the `mqtt out` node:**

| Setting | Value |
|---------|-------|
| Server | `mqtts://<PUBLIC-HOST>:8883`  ← FILL: the broker's public hostname |
| TLS | enabled; verify server cert against the CA you issued |
| Username / Password | `incoplast` / `<the password from the passwd file>` |
| Topic prefix | `spBv1.0/INCOPLAST/` |
| DBIRTH topic | `spBv1.0/INCOPLAST/DBIRTH/<edgeNode>` |
| DDATA topic | `spBv1.0/INCOPLAST/DDATA/<edgeNode>` |
| QoS | 1 |

`<edgeNode>` is the existing SparkPlug edge-node id from the live flow — keep it
identical to what the real flow uses. The group segment (`INCOPLAST`) is what
`edge-transformer-val` lowercases into the tenant (`incoplast`) and matches
against `docs/clients/incoplast.yaml` (`tenant_id: incoplast`).

This is a **tee**, not a redirect — the operator adds a parallel `mqtt out`; the
factory's existing production flow is unchanged.

---

## Verify it's working

```bash
# Incoplast pipeline: transformer receiving MQTT + publishing to the bus
docker logs --tail 50 edge-transformer-val
docker run --rm --network container:edge-transformer-val curlimages/curl:latest \
  -s http://localhost:9102/metrics | grep -E '^(mqtt_|calc_|shadowpub_|outbox_)'

# oeecloud-worker writing to packiot_validation
docker logs --tail 50 oeecloud-worker-val

# Rows landing (run from the app EC2, over stack_packiot-net):
PGPASSWORD=<pw> docker run --rm --network stack_packiot-net postgres:15-alpine \
  psql -h 10.10.10.89 -U postgres -d packiot_validation \
  -c "SELECT id_equipment, count(*) FROM equipment_values WHERE ts_value > now()-interval '10 min' GROUP BY 1 ORDER BY 2 DESC LIMIT 10;"

# CPACK mirror progress
docker logs --tail 50 mirror-worker-go-val
docker run --rm --network container:mirror-worker-go-val curlimages/curl:latest \
  -s http://localhost:9102/metrics | grep -E '^mirror_worker'
```

---

## Teardown

```bash
# Stop + remove the stackval project (keeps the DB):
docker compose -f compose.validation.yml -p stackval down --remove-orphans

# Also drop named volumes (outbox, broker state):
docker compose -f compose.validation.yml -p stackval down --remove-orphans -v

# Drop the isolated database entirely (from the app EC2):
PGPASSWORD=<pw> docker run --rm --network stack_packiot-net postgres:15-alpine \
  psql -h 10.10.10.89 -U postgres -d postgres \
  -c "DROP DATABASE IF EXISTS packiot_validation;"
```

Ask the operator to **remove the tee node** from the live Incoplast Node-RED
when validation is done — leaving it publishing to a torn-down broker is
harmless (connection refused) but should be cleaned up.

---

## Notes / known V1 boundaries

- **Single `shadow-mirror-val`.** ADR-0022 names a *per-tenant* shadow-mirror,
  but the service has no tenant-scope knob; one instance covers both tenants'
  operator actions in `packiot_validation`. Two instances against one un-scoped
  DB would double-write — per-tenant scoping is a V2 refinement.
- **Supporting infra vs services-under-test.** `rabbitmq-val`, `pgbouncer-val`,
  and `edge-api-val` are supporting infra, present because the pipeline needs a
  bus and the CPACK mirror needs a PO-replay HTTP target. They are not the
  refactored artifacts being validated.
- **No bake comparator.** `BAKE_COMPARATOR_ENABLED=false` — the comparator is a
  staging F1↔F3 diff and there is no F1/F3 split in this single-DB harness.
- **Behavior assertions (V3) are not in V1.** V1 stands the environment with
  real data flowing; the golden-fixture pass/fail verdict is V3.
