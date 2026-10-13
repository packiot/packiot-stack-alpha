# Rotate the read-api tenant keys (staging)

read-api authenticates `X-Api-Key` against `QUERY_API_KEYS` (`key:enterprise_id,…`).
`refdata.staging.packiot.app` is **public** and proxies everything to read-api, so a key
is enough to read that tenant's data (real CPACK and Bispharma data on staging).

Until 2026-10 the map and the operators' read keys were **literals in
`compose.staging.yml`**. They are still in git history, so anyone who has (or had) repo
access, or a clone, can use them. **Rotation is mandatory, not optional**: moving the
values to Secrets Manager stops new leaks but does not make the old ones secret again.

## Where the keys live now

| Secrets Manager `packiot/staging/app` key | `.env` variable | Consumer |
|---|---|---|
| `query_api_keys` | `REFDATA_QUERY_API_KEYS` | read-api `QUERY_API_KEYS` (the whole map) |
| `operator_refdata_api_key` | `OPERATOR_REFDATA_API_KEY` | `operator` nginx → `/v1` (CPACK, ent 3) |
| `operator_sbx_refdata_api_key` | `OPERATOR_SBX_REFDATA_API_KEY` | `operator-sbx` nginx (SANDBOX-CPACK, ent 2000003) |
| `operator_bispharma_refdata_api_key` | `OPERATOR_BISPHARMA_REFDATA_API_KEY` | `operator-bispharma` nginx (ent 5) |

- Each operator key must also be an entry of `query_api_keys`.
- `deploy-staging.yml` → step **"Materialize read-api keys"**
  (`scripts/ops/materialize-readapi-keys.py`) rewrites the four `.env` lines on
  **every** deploy. It fails the deploy with an `::error::` naming the missing or
  inconsistent key. It never prints values.
- `compose.staging.yml` uses `${VAR:?…}` for all four, so compose refuses to start
  anything when a key is empty. A fresh box gets them from `app_init.sh`.
- Not affected: front4 and csadmin (Cognito/Firebase Bearer, no shared key),
  `barcode-app` (`BARCODE_REFDATA_API_KEY`, optional and unused by the current build),
  and `dev/` (fake keys against the anonymized seed).
- CI (`scripts/ci/no-literal-readapi-keys.sh`, in PR Validation) fails if a literal comes back.

All commands below run **on the staging app host** (SSM session, as root) unless marked
*workstation*. None of them prints a key. Keep it that way: no `echo $K`, no `set -x`.

```bash
# This repo's checkout on the host = the self-hosted runner's workspace for this repo.
STACK=$(ls -d /opt/actions-runner/_work/packiot-stack-alpha/packiot-stack-alpha 2>/dev/null || echo "$PWD")
SM() { aws secretsmanager get-secret-value --region us-east-1 --secret-id packiot/staging/app --query SecretString --output text; }
envof() { docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n "s/^$2=//p"; }
```

## 1. Seed Secrets Manager with the CURRENT values (the first deploy changes nothing)

Take the values from the **running containers**, which are the source of truth. This
also covers any hand-set `.env` override.

```bash
Q=$(envof read-api QUERY_API_KEYS)
O=$(envof operator REFDATA_API_KEY)
OS=$(envof operator-sbx REFDATA_API_KEY)
OB=$(envof operator-bispharma REFDATA_API_KEY)
for v in Q O OS OB; do x=${!v}; [ -n "$x" ] && echo "$v ok (len ${#x})" || echo "$v EMPTY"; done; unset x   # lengths only
SM | jq --arg q "$Q" --arg o "$O" --arg os "$OS" --arg ob "$OB" \
  '. + {query_api_keys:$q, operator_refdata_api_key:$o,
        operator_sbx_refdata_api_key:$os, operator_bispharma_refdata_api_key:$ob}' \
  | aws secretsmanager put-secret-value --region us-east-1 --secret-id packiot/staging/app \
      --secret-string file:///dev/stdin --query VersionId --output text
# Dry-run the exact deploy check (validation only, no .env write):
APP_SECRET_JSON=$(SM) python3 "$STACK"/scripts/ops/materialize-readapi-keys.py --check
```

Expect `OK (check only): 5 tenant keys; operator keys -> enterprise …=3, …=2000003, …=5`.
Expect a `::warning::` that every key is shorter than 32 characters. That is correct:
the old keys are short, guessable words. Step 3 replaces them.
Keep `Q` in this shell, because step 3's negative test uses it.

## 2. Merge the PR and deploy, then verify

Merge to `staging`. `deploy-staging.yml` runs (or start it with
`gh workflow run deploy-staging.yml --ref staging` on your *workstation*).

- Deploy log: the "Materialize read-api keys" step prints
  `read-api keys materialized into /opt/packiot/.env: 5 tenant keys; …`.
- Containers match Secrets Manager (prints `match` or `MISMATCH`, never a value):

```bash
S=$(SM)
same() { [ "$(printf %s "$1" | sha256sum)" = "$(printf %s "$2" | sha256sum)" ] && echo "$3 match" || echo "$3 MISMATCH"; }
same "$(envof read-api QUERY_API_KEYS)"             "$(jq -r .query_api_keys <<<"$S")"                     read-api
same "$(envof operator REFDATA_API_KEY)"            "$(jq -r .operator_refdata_api_key <<<"$S")"           operator
same "$(envof operator-sbx REFDATA_API_KEY)"        "$(jq -r .operator_sbx_refdata_api_key <<<"$S")"       operator-sbx
same "$(envof operator-bispharma REFDATA_API_KEY)"  "$(jq -r .operator_bispharma_refdata_api_key <<<"$S")" operator-bispharma
```

- Probes print HTTP codes only. `/v1/catalog` is behind the read-api auth middleware
  and does not touch the DB:

```bash
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
K=$(jq -r .operator_refdata_api_key <<<"$S")
echo "no key        $(code https://refdata.staging.packiot.app/v1/catalog)"                     # 401
echo "cpack key     $(code -H "X-Api-Key: $K" https://refdata.staging.packiot.app/v1/catalog)"  # 200
for p in 8083 8085 8087; do echo "operator :$p $(code http://127.0.0.1:$p/v1/catalog)"; done   # 200 x3 (nginx injects the key)
unset K
```

## 3. Generate new keys, update Secrets Manager, redeploy

Generate one 64-hex key for each tenant you keep. The old map held ent 2 (sim) and
ent 4 (Incoplast). Neither has a consumer in this repo, but the `/ext/*` shims also
authenticate through this map. Ask CS whether an external caller uses them. If nobody
does, leave them out: a smaller map exposes less.

```bash
N3=$(openssl rand -hex 32); N5=$(openssl rand -hex 32); NSBX=$(openssl rand -hex 32)
# N2=$(openssl rand -hex 32); N4=$(openssl rand -hex 32)   # only if 2 / 4 are still needed
NEWQ="$N3:3,$NSBX:2000003,$N5:5"                           # append ,$N2:2,$N4:4 if kept
SM | jq --arg q "$NEWQ" --arg o "$N3" --arg os "$NSBX" --arg ob "$N5" \
  '. + {query_api_keys:$q, operator_refdata_api_key:$o,
        operator_sbx_refdata_api_key:$os, operator_bispharma_refdata_api_key:$ob}' \
  | aws secretsmanager put-secret-value --region us-east-1 --secret-id packiot/staging/app \
      --secret-string file:///dev/stdin --query VersionId --output text
APP_SECRET_JSON=$(SM) python3 "$STACK"/scripts/ops/materialize-readapi-keys.py --check   # no warnings now
unset N2 N3 N4 N5 NSBX NEWQ
```

Redeploy (*workstation*: `gh workflow run deploy-staging.yml --ref staging`). read-api
loads the map once at boot. The deploy's `up -d` recreates read-api and the three
operators, because their environment changed.

Verify:

1. Run the step 2 checks again: `match` x4, `401` without a key, `200` with the new
   key, `200` x3 through the operators.
2. **The old keys are dead.** `Q` still holds the old map from step 1:

```bash
for k in $(tr ',' '\n' <<<"$Q" | sed 's/:[0-9]*$//'); do
  echo "old key -> $(code -H "X-Api-Key: $k" https://refdata.staging.packiot.app/v1/catalog)"   # 401 each
done; unset Q k
```

3. Smoke-test the UIs: open operator, operator-sbx and operator-bispharma, then load a
   PO list and a downtime list (both are `/v1` reads). front4 and csadmin need no change.
4. Sandbox E2E (`npm run test:sandbox`): export `REFDATA_KEY_CPACK` and `REFDATA_KEY_SBX`
   from Secrets Manager in the shell that runs it. When they are unset, the parity
   suite skips and the reset suite fails loudly.

## 4. Done

The old keys now return 401. They are still in git history, but they open nothing.
Rewriting history is not needed and not worth the disruption to forks.

## Production

`compose.production.yml` has never committed values (`${REFDATA_QUERY_API_KEYS:-}`,
`${OPERATOR_REFDATA_API_KEY:-}`). They come from the `packiot/production/*` secrets
(`docs/adr/reference/production-recut-runbook.md`). Use fresh `openssl rand -hex 32`
keys there. Never reuse a staging key.
