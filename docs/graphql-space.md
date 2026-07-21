# GraphQL Space (AWS AppSync) — staging

A minimal, **wired but intentionally near-empty** managed GraphQL API on staging.
The point is to have the door open: a real, Cognito-authed GraphQL endpoint that
proves out auth + resolvers and is ready to grow a schema **when a concrete need
appears** — not before. Today it exposes exactly one placeholder query.

- **Terraform:** [`terraform/staging/appsync.tf`](../terraform/staging/appsync.tf)
- **API name:** `packiot-staging-graphql`
- **API id:** `r5jjbcspazfx7mhhiqu5xwm5qa`
- **Endpoint:** `https://q37zloexjveudjzgdaszmlyfwm.appsync-api.us-east-1.amazonaws.com/graphql`
- **Region:** `us-east-1`
- **Reversible:** `terraform destroy` (or `-target` the AppSync resources) removes it cleanly.

The live endpoint id can drift if the API is destroyed/recreated — always trust
the Terraform outputs (`terraform output graphql_endpoint` / `graphql_api_id`)
over the values pasted here.

## What's in it right now

The entire schema:

```graphql
schema { query: Query }

type Query {
  _ping: String! @aws_api_key @aws_cognito_user_pools
}
```

`_ping` resolves locally against a **NONE (local) data source** — a trivial VTL
unit resolver that returns the literal string `"pong"`. No backend, no network
hop, no per-request backend cost. It exists only to prove the API + auth + a
resolver work end to end.

```console
$ curl -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $API_KEY" \
    -d '{"query":"query { _ping }"}'
{"data":{"_ping":"pong"}}
```

## How auth works

Two authorization providers are configured on the one API:

| Mode | Role | How to use |
|------|------|-----------|
| **Amazon Cognito user pools** (PRIMARY) | The real, tenant-aware auth. Shared with the staging Cognito pool `aws_cognito_user_pool.staging` (ADR-0034), the same pool front4 (Amplify) signs into and refdata-api verifies against. | Send `Authorization: <Cognito access/id token>`. |
| **API key** (ADDITIONAL) | Dev/testing convenience only, so you can curl without minting a token. **Not** the real auth. | Send `x-api-key: <key>`. |

Because more than one provider is configured, **AppSync gates each field by
directive**. A field with *no* directive is reachable only by the API's default
mode (Cognito). `_ping` is annotated with **both** `@aws_api_key` and
`@aws_cognito_user_pools`, so either credential works. Any new field you add is
**Cognito-only by default** unless you also tag it `@aws_api_key`.

Get the credentials:

```console
# dev API key (sensitive Terraform output)
$ cd terraform/staging && terraform output -raw graphql_api_key

# endpoint
$ terraform output -raw graphql_endpoint
```

A request with no auth header at all is correctly rejected
(`UnauthorizedException`), confirming the space is not open to the world.

The dev API key has a fixed expiry (`2027-07-01`, AppSync caps key lifetime at
365 days). Rotate it before then by bumping `expires` in `appsync.tf` and
re-applying — or, once a real consumer exists, give that consumer a Cognito
token and stop relying on the key.

## How to expand it

The whole design is "add types + resolvers backed by a real data source." Recipe:

1. **Extend the schema** in `appsync.tf` — add your types/fields. Tag each field
   with the auth mode(s) that may reach it (`@aws_cognito_user_pools` for real
   callers; add `@aws_api_key` only if dev-key access is wanted).
2. **Add a data source** (`aws_appsync_datasource`). Pick the backend:
   - **HTTP → refdata-api `/v1/*`** (the read plane). `type = "HTTP"`, point
     `http_config.endpoint` at the refdata base URL. This is the most likely
     first expansion: GraphQL becomes a typed façade over the existing REST read
     API. Forward the caller's identity so refdata's tenant isolation still
     applies (resolver copies the auth header / a tenant claim into the request).
   - **Lambda** (`type = "AWS_LAMBDA"`) for custom logic or mutations — add an
     IAM role letting AppSync invoke the function.
   - **RDS / RDS Data API** (`type = "RELATIONAL_DATABASE"`) for direct DB reads.
3. **Add a resolver** (`aws_appsync_resolver`) wiring `type`+`field` to that data
   source, with request/response mapping templates (VTL) or a JS (`APPSYNC_JS`)
   resolver.
4. `terraform plan -target=...` the new resources, apply, and test with the same
   curl pattern.

The existing `_ping` NONE resolver is a working template for the mapping-template
shape; copy it and swap the data source.

## Cost

Pay-per-operation. AWS free tier covers **250k query/data-modification ops/mo**
and 250k real-time updates — an idle API bills **~$0**. Field-level logging is
set to **ERROR** only (a few cents of CloudWatch ingestion, if any), and X-Ray
tracing is **off**. There is no provisioned capacity to pay for. The NONE data
source means `_ping` incurs no backend cost at all.

## Reversibility

Everything lives in `terraform/staging/appsync.tf` (the API, NONE data source,
resolver, dev API key, and the CloudWatch-logging IAM role). Remove it with a
targeted destroy:

```console
$ cd terraform/staging
$ terraform destroy \
    -target=aws_appsync_resolver.ping \
    -target=aws_appsync_datasource.none \
    -target=aws_appsync_api_key.dev \
    -target=aws_appsync_graphql_api.staging \
    -target=aws_iam_role_policy_attachment.appsync_logs \
    -target=aws_iam_role.appsync_logs
```

It touches nothing in prod, nothing in GCP/Firebase, and nothing else in the
staging stack.
