---
title: Add an API endpoint
layer: guide
owner_area: serving
last_verified: 2026-10-13
---
# Add an API endpoint

> **Build & operate · how-to.** Add or change an HTTP endpoint so that its OpenAPI
> documentation, tests and tenant fencing come with it. Up: [Build & operate](../index.md)

**Goal:** a new endpoint that is documented in the [API reference](../../reference/api/index.md)
and the API portal, enforced by CI, and safe across tenants.

## The three rules

1. **The spec ships with the code.** Every API has a CI test that fails if a route and the
   spec disagree (in both directions), and a completeness test that fails if an operation
   lacks an id, summary, description, tag, success example, or a description on any
   error, parameter or field.
2. **Fence the write on the column the reads scope on.** If the reads filter on
   `equipments.id_enterprise`, stamping the new row with the caller's tenant is not enough:
   check that every referenced id belongs to the caller, and test it with *another
   tenant's* id. Two cross-tenant bugs were found this way on 2026-10-13.
3. **The tenant comes from the credential**, never from a client-supplied id.

## edge-api (NestJS)

1. Add a vertical slice under `src/usecases/<domain>/<feature>/` (controller, service,
   module, `dto/`), with the DAO in `src/data/DAO/`. Mutations use `POST`; set
   `res.locals.logData` for the audit log; throw `HttpException` subclasses.
2. Document it with decorators: the controller's tag (from `src/openapi/openapi.ts`),
   `@ApiOperation({ summary, description, operationId })`, the auth decorator
   (`ApiTenantAuth()` or `ApiCsAdminAuth()` from `src/openapi/api-docs.ts`), and every
   error status the service can throw. Every DTO field needs `@ApiProperty` with a
   description and an example. No real customer data in examples.
3. Export and test:
   ```sh
   npm run openapi:export        # rewrites openapi/edge-api.openapi.json
   npm test -- src/openapi       # completeness + "committed spec is fresh"
   ```

## Go services

1. Register the route in the service's single registration function (`registerRoutes`), so
   the drift test sees it.
2. Document it:
   - **read-api** generates its spec from its route tables (`cmd/refdata-api/openapi.go`);
     add the hand-written enrichment (summary, params, examples) for the new path.
   - **Other services** embed `openapi.json` next to the server code; add the operation there.
3. Test and export:
   ```sh
   go test ./...          # drift + completeness tests in the service
   make openapi           # refresh docs/api/openapi/*.openapi.json (CI checks this)
   ```

## Before you merge

- **Exposure:** check what nginx forwards for the service's public host
  (`terraform/staging/user_data/nginx_setup.sh`). A host that proxies `location /` without
  SSO exposes every new route, including ops ones. See [Change nginx config](../operate/nginx-config-changes.md).
- **Word check:** under `services/`, the ADR-0061 packml ratchet fails on new "packml"
  mentions. Reword prose; if the spec must name a real wire field, add an allowlist entry
  with a reason and expiry. Don't squeeze lines to game the count.

## Check it worked

After the deploy: the operation shows in the [API portal](https://api.staging.packiot.app/docs/)
(SSO) and, after the next wiki build, in the generated [API reference](../../reference/api/index.md).
