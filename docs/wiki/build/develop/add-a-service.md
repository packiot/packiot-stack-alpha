---
title: Add a service
layer: guide
owner_area: platform
last_verified: 2026-10-13
---
# Add a service

> **Build & operate · how-to.** Add a new in-tree Go service under `services/` so that it builds,
> runs in dev, is tested in CI, deploys to staging, is monitored, and is documented. For engineers.
> Up: [Build & operate](../index.md)

**Goal:** a new service that every gate knows about: dev slice, CI, the staging deploy's
service-state gate, Prometheus, and the docs (README, component page, service catalog).

The checklist is long because each place catches a different failure. Most of them are one line.

```text
 services/<svc>/            code, Dockerfile, README, openapi.json
      │
      ├─ dev/services/<svc>.yml + dev/compose.yml include   ─► make dev SVC=<svc>
      ├─ dev/e2e/smoke.sh case + dev-slices.yml slice        ─► "dev slices gate" (required)
      ├─ go-services.yml (paths + matrix)                    ─► vet / test -race / build
      ├─ compose.staging.yml block (+ IP, healthcheck)        ─► Deploy to Staging + service-state gate
      ├─ monitoring/prometheus/prometheus.yml job            ─► metrics, alerts, dashboards
      └─ docs: README, Makefile openapi, component page, service-catalog row
```

## Before you start

- Read the shared conventions in
  [`services/README.md`](https://github.com/packiot/packiot-stack-alpha/blob/staging/services/README.md#shared-conventions-go-services).
- Have the dev stack working: [Local development](local-development.md).
- Know where the service fits: [Architecture overview](../../understand/architecture/overview.md) and
  [Compose topology](../../understand/components/compose-topology.md).

## Steps

### 1. Write the service the way the others are written

Copy the skeleton of a small existing service (`services/oeecloud-fanout/` or
`services/ingest-shim/`). The conventions:

| Convention | What to do | Why |
|---|---|---|
| Build | Multi-stage `Dockerfile`: `golang:1.25-alpine` builder, `gcr.io/distroless/static-debian12:nonroot` runtime | Staging builds every image on the app host during the deploy; no registry |
| Health | A `--healthcheck` flag that probes the binary's own health endpoint and exits 0/1 | Distroless has no shell, so compose healthchecks call the binary itself |
| Credentials | Read DB/RabbitMQ credentials from AWS Secrets Manager by default; `CREDS_SOURCE=env` reads plain env (what dev uses). See `services/oeecloud-fanout/internal/secrets/` | No secrets in compose or `.env.dev`; dev needs no AWS |
| Metrics | Serve Prometheus metrics on `/metrics` | Step 7 scrapes it |
| Traces | Export OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set; leave it unset in dev | Staging sends to `tempo:4317` or `alloy:4317`; dev has no Tempo |
| Tenancy | Take the tenant from the credential, never from a client-supplied id | [Tenancy & security](../../understand/architecture/tenancy-and-security.md) |
| Words | No new "packml" wording | The `packml ratchet` check fails ([ADR-0061](../../reference/adr-index.md)) |

Run the tests the way CI will:

```bash
cd services/<svc>
go vet ./... && go test -race -timeout 60s ./... && go build ./...
```

### 2. Add the dev fragment

Create `dev/services/<svc>.yml`. Start it with a contract header comment (inputs, outputs, external
dependencies, how it differs from staging), as `dev/services/barcode-service.yml` does. Then:

- `build: ../../services/<svc>` (paths in a fragment resolve from the fragment's own folder);
- `depends_on` with `condition: service_healthy` on everything it reads;
- `CREDS_SOURCE: env` and values from `dev/.env.dev` (fake values only);
- host ports bound to `127.0.0.1`;
- the same `healthcheck` as staging.

Add the fragment to the `include:` list in `dev/compose.yml`. Check:

```bash
make dev SVC="<svc>"
make dev-ps
```

You should see your service `healthy` and its port on `127.0.0.1:…`.

### 3. Add a smoke check and a slice

- In `dev/e2e/smoke.sh`, add a `case` for the service: its health endpoint **and one real request that
  reaches its data** (a row, a routed message). Health alone proves nothing.
- In `.github/workflows/dev-slices.yml`, add the service to a slice's `up:` and `smoke:` lists (or a new
  slice). Slice paths already include `services/**`.

```bash
make dev-smoke SVC="<svc>"
```

You should see `ok` lines and exit code 0.

### 4. Add it to Go CI

In `.github/workflows/go-services.yml` add the service in **two** places: the `paths:` filter
(`services/<svc>/**`) and the `matrix.service` list. The job runs `go vet`, `go test -race` and
`go build` (govulncheck and golangci-lint are non-blocking).

### 5. Add it to the staging compose

Add a block to `compose.staging.yml`, modelled on an existing one (for example `barcode-service`):

- `build: ./services/<svc>`, `container_name: <svc>`, `restart: unless-stopped`, `env_file: [.env]`;
- a **fixed IP** on `packiot-net`: pick a free address and record it in the IP allocation comment at the
  top of the file;
- `healthcheck` calling `--healthcheck`;
- `logging` with `max-size`/`max-file`, like the other services;
- `profiles: [<name>]` **only** if the service must be off by default. Profiles that run on staging come
  from `COMPOSE_PROFILES` in the host's `.env`, plus `shared-tee`.

The `Validate compose files` check (`pr-validation.yml`) runs `docker compose config` on this file and on
`dev/compose.yml`.

You do **not** need to add the service to the deploy gate: the post-deploy service-state gate in
`deploy-staging.yml` reads the service list from the rendered compose config, so a new service is
checked automatically (running, healthy if it has a healthcheck, one-shots exited 0).

If the service needs a secret, create it in Secrets Manager and give the app host's role read access in
Terraform (`terraform/staging/`); never put it in compose. See [Rotate secrets](../operate/secrets-rotation.md).

### 6. Expose it, only if it must be reachable from outside

Nothing is public by default. A public hostname or path is an nginx change in
`terraform/staging/user_data/nginx_setup.sh`, which the deploy does **not** apply. Follow
[Change nginx config](../operate/nginx-config-changes.md).

### 7. Monitor it

- Add a scrape job to `monitoring/prometheus/prometheus.yml`:

    ```yaml
      - job_name: <svc>
        static_configs:
          - targets: ['<svc>:<metrics-port>']
    ```

    The deploy reloads Prometheus, so the job is live after the merge.
- Add alerts to `monitoring/prometheus/rules.yml` if the service can fail silently.
- Add panels to a dashboard in `grafana/dashboards/` (`audience/` for the role boards, `library/` for
  the detailed ones). The `dashboard-lint` workflow checks datasource pinning and that every Prometheus
  tile returns live data on staging. See [Observability](../../understand/components/observability.md).

### 8. If it serves HTTP: publish the API contract

Follow [Add an API endpoint](add-an-api-endpoint.md) for the spec and its tests, then:

- add `<svc>:<path to openapi.json>` to `OPENAPI_EMBEDDED` in the `Makefile`, and the path to the
  `paths:` of `.github/workflows/openapi-export.yml`;
- run `make openapi` and commit `docs/api/openapi/<svc>.openapi.json`. The wiki build generates the
  reference page `reference/api/<svc>.md` from it.

Showing it in the [API portal](https://api.staging.packiot.app/docs/) also needs an nginx
`/docs/specs/<svc>.json` location (step 6).

### 9. Document it

| Where | What |
|---|---|
| `services/<svc>/README.md` | The same sections as the others: What it does · Where it fits · Status and environments · Interfaces · Configuration · Run locally · Operating it · Code layout · Related docs. Link back to the component page and the service catalog |
| `services/README.md` | A row in the services table |
| `docs/wiki/understand/components/<svc>.md` | A component page using the layer-3 template in `docs/WIKI-STYLE.md`, plus its entry in `nav:` of `wiki/mkdocs.yml` |
| [Service catalog](../../reference/service-catalog.md) | A row: README, wiki page, API page, dashboard |
| [API reference index](../../reference/api/index.md) | A row, if it serves HTTP |

See [Write docs](write-docs.md).

### 10. Open the PR and deploy

Open the PR into `staging` and wait for every check on the head commit, including `dev slices gate`
and `Go Services CI` ([Branches and merging](branches-and-merging.md)). After the merge,
**Deploy to Staging** builds and starts it.

## Check it worked

```bash
gh run list -R packiot/packiot-stack-alpha -w deploy-staging.yml --limit 3
```

Then on the app host ([Runbooks → SSM access](../operate/runbooks.md#ssm-access-to-a-host)):

```bash
docker ps --filter name=<svc> --format '{{.Names}}\t{{.Status}}\t{{.CreatedAt}}'
docker logs --since 10m <svc> | tail -20
```

You should see the container `Up … (healthy)`, created after your merge. In Grafana → Explore → Prometheus,
`up{job="<svc>"}` should be 1.

## If it went wrong

| Symptom | Cause | Fix |
|---|---|---|
| `make dev SVC=<svc>` hangs, then fails | Healthcheck never passes, or a dependency is not healthy | `docker compose -f dev/compose.yml --env-file dev/.env.dev logs <svc>` |
| Deploy fails at the service-state gate with `<svc>: state=created` or `exited` | Container did not start (port clash, missing env, bad IP) | The gate prints the last log lines; fix and push |
| `Validate compose files` fails | YAML or compose schema error, often a duplicate IP or key | Run `docker compose -f compose.staging.yml config --no-interpolate -q` locally |
| `OpenAPI export is current` fails | Committed spec is stale | `make openapi && git add docs/api/openapi` |
| `up{job="<svc>"}` is 0 | Wrong port or path in the scrape job, or `/metrics` not served | Compare the job's target with the port the service listens on; query `up{job="<svc>"}` in Grafana Explore |

## Next

- [Add an API endpoint](add-an-api-endpoint.md)
- [Add a migration](add-a-migration.md), if the service needs new tables
- [Deploy](../operate/deploy.md)
