# packiot-stack-alpha

The Packiot OEE platform's integration monorepo: services, Docker Compose (staging), Terraform, database
migrations and documentation.

- **Documentation front door:** [`docs/README.md`](docs/README.md) — architecture, the migration program,
  staging/production, runbooks (the end-to-end guide: chapters 1–9 in order).
- **Local development:** [`dev/README.md`](dev/README.md) — ADR-0060 service slices on a shared data plane, with an
  anonymized 7-day seed of the largest client (`ghcr.io/packiot/devseed`) and a dev Cognito pool.

## Local development in one minute

```sh
git submodule update --init --recursive
docker login ghcr.io                      # GitHub token with read:packages (the seed image is private)
make dev                                  # Tier 0: postgres (seeded), rabbitmq, mosquitto, redis, minio
make dev SVC=grafana                      # a slice: grafana + what it depends on
FRONT4_DIR=../front4-staging make dev SVC=front4   # read-api + CORS proxy + front4 at http://localhost:5173
make dev-down                             # stop (volumes kept)
```

Dev users and passwords (dev Cognito pool, tenant 3):
`aws secretsmanager get-secret-value --secret-id packiot/dev/cognito --query SecretString --output text`.
Everything binds `127.0.0.1`; the only outbound calls are to Cognito (login).

The environment ladder is **development (dev/ slices) → staging (integration and e2e) → production**
([ADR-0060](docs/adr/0060-local-development-environment-and-cpack-dev-seed.md)).

The previous all-in-one local harness (`compose.development.yml`, `make up`) was removed in ADR-0060 P2;
its README is archived at [`docs/archive/legacy-local-harness-README.md`](docs/archive/legacy-local-harness-README.md).

`make help` lists the remaining targets (dev environment and staging Terraform).
