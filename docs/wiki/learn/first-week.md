---
title: Your first week
layer: 0
owner_area: platform
last_verified: 2026-10-13
---
# Your first week

> **Learn · tutorial.** A guided first week for a new engineer: run the stack on your laptop, follow
> one production counter through every hop, ship a small change to staging, and learn where to look
> when something breaks. Up: [Learn](index.md)

**Goal:** by Friday you have the dev stack running, you can explain how a PLC counter becomes an OEE
number on a screen, and you have merged one change that is running on staging.

!!! info "Dev, staging, production"
    **Dev** is Docker Compose on your laptop with an anonymized week of CPACK data. **Staging** is the new
    stack on AWS, where every merge to `staging` deploys. **Production** still runs the legacy platform
    for most clients. See [Environments](../understand/architecture/environments.md).

## Before you start

- A GitHub account in the `packiot` organization, and a token with `read:packages` (the dev database
  image is a private package).
- Docker with the Compose plugin (v2), `make`, `git`, `gh`. Go, Node and Python are not needed on the
  host: every service builds in its own container.
- For day 3 and later: AWS access to the staging account (ask your lead), for SSM and Secrets Manager.

## Day 1 — run the stack locally

1. Clone the stack with its submodules and switch to the integration branch:

    ```bash
    git clone --recurse-submodules git@github.com:packiot/packiot-stack-alpha.git
    cd packiot-stack-alpha
    git checkout staging
    git submodule update --init --recursive
    docker login ghcr.io          # user = your GitHub login, password = the read:packages token
    ```

2. Start the data plane (Tier 0):

    ```bash
    make dev
    make dev-ps
    ```

    The first start loads the seed into PostgreSQL (2–4 minutes). You should see `postgres`, `rabbitmq`,
    `mosquitto`, `redis` and `minio` all `healthy`, with every port on `127.0.0.1`.

3. Open Grafana:

    ```bash
    make dev SVC="grafana"
    make dev-smoke SVC="grafana"
    ```

    Browse to <http://127.0.0.1:3000>, log in as `admin` / `admin`, skip the password change. The
    dashboards are in the folders *Audience* and *Library*. Database panels work; Prometheus, Loki and Tempo
    panels are empty in dev (there is no observability stack locally).

4. Open front4, the product frontend. It runs from its own clone because it deploys separately:

    ```bash
    git clone -b staging git@github.com:packiot/front4.git ../front4-staging
    FRONT4_DIR=../front4-staging make dev SVC=front4
    ```

    Browse to <http://localhost:5173>. Log in with `dev-admin@example.com`; the password is in Secrets
    Manager (`packiot/dev/cognito`), see
    [Local development → Logging in](../build/develop/local-development.md#logging-in-to-the-spas).

**Check it worked:** `make dev-smoke SVC="postgres grafana"` prints only `ok` lines.

**If it went wrong:** postgres stays unhealthy → an old volume skipped the seed load; run `make dev-reset`.
`make dev` fails pulling `ghcr.io/packiot/devseed` → `docker login ghcr.io` again. More in
[Local development](../build/develop/local-development.md).

## Day 2 — follow one counter from PLC to screen

Read [A counter's journey](../understand/architecture/data-journey.md) first. Then watch the same
journey happen on your laptop. In dev, `seed-replay` plays the role of the factory: it republishes the
seed's own week as Sparkplug B messages at the current time.

```text
 seed-replay ─MQTT─► mosquitto ─► sparkplug-decoder ─► RabbitMQ `oee` ─► stream-engine
 (the "PLC")                      (total → increment)                     │ writes
                                                                          ▼
 front4 ◄── read-api ◄── serving.* ◄── gold (OEE per hour/shift) ◄── silver (clean facts)
```

1. Start the pipeline and wait a few minutes:

    ```bash
    make dev SVC="seed-replay stream-engine read-api-cors"
    make dev-smoke SVC="seed-replay"
    ```

    You should see `ok seed-replay: live silver rows at now (…)`.

2. **MQTT** — the raw Sparkplug messages (the payload is binary protobuf; look at the topics):

    ```bash
    DC="docker compose -f dev/compose.yml --env-file dev/.env.dev"
    $DC exec mosquitto mosquitto_sub -t 'spBv1.0/#' -C 5 -v | cut -c1-120
    ```

3. **Decoder → RabbitMQ** — the decoder turns each running total into an increment and publishes it:

    ```bash
    $DC logs --since 2m sparkplug-decoder | tail -5
    $DC exec rabbitmq rabbitmqctl list_queues name messages consumers | grep stream-engine
    ```

    `stream-engine-q` should have a consumer and few or no waiting messages.

4. **Silver** — the clean fact per equipment and timestamp:

    ```bash
    PSQL="$DC exec -T postgres psql -U postgres -d packiot_analytics -c"
    $PSQL "SELECT id_equipment, ts_value, gross_production_incr, net_production_incr, speed, state
             FROM silver.equipment_values
            WHERE ts_value > now() - interval '3 minutes'
            ORDER BY ts_value DESC LIMIT 10;"
    ```

5. **Minute buckets** (a TimescaleDB continuous aggregate over silver):

    ```bash
    $PSQL "SELECT ts_value, id_equipment, gross_production_incr, net_production_incr
             FROM silver.equipment_categorical_1min
            WHERE ts_value > now() - interval '15 minutes'
            ORDER BY ts_value DESC LIMIT 10;"
    ```

6. **Gold** — the OEE numbers stream-engine's jobs compute per hour:

    ```bash
    $PSQL "SELECT id_equipment, ts_value, oee, oee_a, oee_p, oee_q, gross, net, recalc_needed
             FROM gold.equipment_oee_hourly
            WHERE ts_value > now() - interval '3 hours'
            ORDER BY ts_value DESC, id_equipment LIMIT 10;"
    ```

    `oee_a`, `oee_p`, `oee_q` are Availability, Performance and Quality. `recalc_needed = true` means the
    row is waiting for the next rollup tick.

7. **read-api** — what the screens call (tenant 3, with the seed's fake read key):

    ```bash
    KEY=dev-read-key-3                     # fake read key for tenant 3 in the dev seed
    curl -s -H "X-Api-Key: $KEY" http://127.0.0.1:9104/v1/operator-entities | jq '.[0]'
    ```

8. **front4** — open Mission Control in the front4 tab from day 1 and find a line whose numbers you
   just queried.

**Check it worked:** you can say, for one equipment, which hop wrote each number and how old it is.
Compare with the freshness column in [A counter's journey](../understand/architecture/data-journey.md#hop-by-hop).

Go deeper: [sparkplug-decoder](../understand/components/sparkplug-decoder.md),
[stream-engine](../understand/components/stream-engine.md),
[read-api](../understand/components/read-api.md),
[Analytics DB schemas](../understand/components/analytics-db-schemas.md).

## Day 3 — ship a small change to staging

Pick something tiny with your lead: a clearer log line, a missing test, a typo in a README. Doing it in a
Go service exercises the whole path. Follow [Branches and merging](../build/develop/branches-and-merging.md);
the short version:

1. Branch from `staging`:

    ```bash
    git fetch origin
    git switch -c chore/<short-name> origin/staging
    ```

2. Change the code, then run what CI runs for that service:

    ```bash
    cd services/<service>
    go vet ./... && go test -race -timeout 60s ./... && go build ./...
    cd -
    make dev SVC="<service>" && make dev-smoke SVC="<service>"
    ```

    `make dev` does not rebuild an image it already has; after a code change use
    `docker compose -f dev/compose.yml --env-file dev/.env.dev up -d --build <service>`.

3. Open the PR:

    ```bash
    git push -u origin HEAD
    gh pr create --base staging --title "chore(<service>): <what>" --body "<why, how you verified it>"
    ```

4. Wait for **every** check on the head commit. Two are required by the `staging` ruleset:
   `Validate compose files` and `dev slices gate`. Others (Go CI, gitleaks, RLS isolation…) are not
   required but must be green too:

    ```bash
    gh pr checks --watch
    ```

5. Merge (squash), then watch the deploy:

    ```bash
    gh pr merge --squash --delete-branch
    gh run list -R packiot/packiot-stack-alpha -w deploy-staging.yml --limit 3
    gh run watch <run-id> -R packiot/packiot-stack-alpha
    ```

**Check it worked:** a green run is not enough. Confirm the container was recreated after your merge and
your change shows (log line, behaviour). See [Deploy → check it worked](../build/operate/deploy.md#check-it-worked)
and [Runbooks → SSM access](../build/operate/runbooks.md#ssm-access-to-a-host).

**If it went wrong:** a run that says *Superseded by …* deployed nothing on purpose: a newer commit's run
owns staging. Other failures: [Deploy → if it went wrong](../build/operate/deploy.md#if-it-went-wrong).

## Days 4–5 — your subsystem, and on-call basics

1. **Read the subsystem you will own**, top down: its page under
   [Understand → subsystems](../understand/index.md), then its component pages, then the code paths in each
   page's *Source map*. Use the [Service catalog](../reference/service-catalog.md) to jump between README,
   wiki page, API reference and dashboard.

2. **Learn the dashboards on staging** (Grafana, SSO):

    | Dashboard | Use it for |
    |---|---|
    | [Overview](https://grafana.staging.packiot.app/d/v2-overview) | Firing alerts, is the stack alive, is data landing |
    | [① CS · Client health](https://grafana.staging.packiot.app/d/aud-cs) | One client's data and OEE, the way Customer Success sees it |
    | [② Platform · SRE](https://grafana.staging.packiot.app/d/aud-sre) | Hosts, containers, brokers, database |
    | [③ Pipeline · Data eng](https://grafana.staging.packiot.app/d/aud-data) | The pipeline hop by hop, rollup lag |
    | [🔎 Ingest debug](https://grafana.staging.packiot.app/d/aud-debug-ingest) | Why a client's data is not arriving |

3. **Walk through the runbooks** without changing anything: open an SSM session to the app host, list
   the containers, read a service's logs, check DB health. All in
   [Runbooks](../build/operate/runbooks.md); database work in the [DBA guide](../build/operate/dba-guide.md).

4. **Learn the rules that came from incidents**, in [Branches and merging](../build/develop/branches-and-merging.md#database-changes)
   and [Add a migration](../build/develop/add-a-migration.md#timescaledb-rules-from-real-incidents). Read
   the *Failure modes* section of your subsystem's component pages.

5. **Know what never to touch:** `development`, `master`, `main` and `production` branches in any
   repository (some deploy straight to customers, see [Repositories](../reference/repositories.md)), and the
   legacy production platform.

**Check it worked:** you can answer "client X says line Y shows no data — where do you look first?" using
Ingest debug and the [Troubleshooting OEE](../use/troubleshooting-oee.md) page.

## Next

- [Onboard a client end to end](onboard-a-client-end-to-end.md) — the other tutorial, on the sandbox tenant.
- [Glossary](../reference/glossary.md) — OEE, line lead, gross/net, the medallion layers.
- [Add a service](../build/develop/add-a-service.md), [Add a migration](../build/develop/add-a-migration.md),
  [Add an API endpoint](../build/develop/add-an-api-endpoint.md).
