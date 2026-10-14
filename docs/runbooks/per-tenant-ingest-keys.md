# Per-tenant ingest keys (shared ingest door)

Moves the staging shared ingest door (`sparkplug-agent-shared`, reached through
`ingest.staging.packiot.app:8449/v1/tags` and `cpack-ingest.staging.packiot.app:8447/v2/tags`)
from one `X-Ingest-Key` for every tenant to **one key per tenant, bound to that tenant's
SparkPlug group**. Decided 2026-10-14.

## Why

Before this change a holder of the shared key (any onboarded box inside the security-group
allowlist) could post data as another tenant just by naming that tenant's group in the body or
in `X-Ingest-Group`. With per-tenant keys the group a request names must be one its key is bound
to; anything else is `403 key not authorised for group` and is counted as
`sparkplug_agent_http_ingest_total{outcome="rejected_key_scope"}`.

## How it works

| Setting (compose `sparkplug-agent-shared`) | Default | Meaning |
|---|---|---|
| `AGENT_INGEST_KEYS_SECRET_ID` | empty (no map) | Secrets Manager id of the key map. Staging: `packiot/staging/agent-ingest-keys` (Terraform `aws_secretsmanager_secret.agent_ingest_keys`) |
| `AGENT_INGEST_KEYS_JSON` | empty | Same map inline (dev/tests). Set one or the other, not both |
| `AGENT_INGEST_LEGACY_KEY_ALLOWED` | `true` | Keep accepting the old shared `AGENT_INGEST_API_KEY` for any group (deprecated: counted as outcome `legacy_key`, WARN once per group per 10 min) |
| `AGENT_INGEST_API_KEY` | from `.env` | The old shared key |

Key map format, **hashes only**:

```json
{
  "<sha256 hex of CPACK's key>": ["CPACK"],
  "<sha256 hex of Bispharma's key>": ["BISPHARMASTAGING"]
}
```

- Keys are 256-bit random values, so a plain SHA-256 is enough (no salt or bcrypt: there is no
  low-entropy password to brute-force). The map itself reveals nothing usable.
- Every presented key is hashed and compared against every entry in constant time.
- The agent reads the map once at start; changing it needs a restart of
  `sparkplug-agent-shared`.
- A configured map that cannot be read (missing secret, no permission, a raw key pasted instead
  of a hash) makes the agent **exit at start**. It does not silently fall back to the shared key.
- Responses: unknown or missing key → 401; shared key after the flag is off → 401 (log
  `reason="legacy shared key disabled …"`); right key, wrong group → 403. Logs carry the group
  and the key's bound groups (`key_groups=CPACK`), never key material.

Merging the code changes nothing: with the map unset and the flag at its default, the agent
behaves exactly as before.

## Rollout (staging)

Steps 1–3 are ours. Step 4 touches the client's factory side and has to be coordinated with each
client; step 5 waits until every client is done.

1. **Create the secret container** (Terraform, user-gated):
   `terraform -chdir=terraform/staging apply -target=aws_secretsmanager_secret.agent_ingest_keys`.
2. **Generate each tenant's key on the app host** (via SSM; the key never leaves the host except
   to its client), and store only the hash map:

   ```sh
   umask 077
   for g in CPACK BISPHARMASTAGING; do
     openssl rand -hex 32 > /opt/packiot/ingest-keys/$g.key      # the key itself (host only)
   done
   python3 - <<'PY' > /opt/packiot/ingest-keys/map.json
   import hashlib, json, pathlib
   d = pathlib.Path("/opt/packiot/ingest-keys")
   print(json.dumps({hashlib.sha256(p.read_text().strip().encode()).hexdigest(): [p.stem]
                     for p in sorted(d.glob("*.key"))}))
   PY
   aws secretsmanager put-secret-value --region us-east-1 \
     --secret-id packiot/staging/agent-ingest-keys \
     --secret-string file:///opt/packiot/ingest-keys/map.json
   ```

   Do not print the `.key` files in a terminal that is logged or shared. `map.json` holds hashes only.
3. **Turn the map on** with the shared key still allowed: set
   `AGENT_INGEST_KEYS_SECRET_ID: ${AGENT_INGEST_KEYS_SECRET_ID:-packiot/staging/agent-ingest-keys}`
   in `compose.staging.yml` (a PR, so a re-init keeps it), deploy, then check the start-up log line
   `ingest auth per_tenant_keys=2 … legacy_key_allowed=true` and the WARN listing the tenants that
   still use the shared key. Ingest is unchanged at this point.
4. **Hand each client its own key** (coordinated per client, one at a time):
   - **CPACK** (Node-RED tee posting to `cpack-ingest…:8447/v2/tags`): CPACK's team replaces the
     `X-Ingest-Key` header value in their tee's HTTP request node with the CPACK key. Send the
     key through a secure channel, not chat or email.
   - **Bispharma** (generated reader on our edge box posting to `ingest…:8449/v1/tags`): replace
     `INGEST_KEY` in the box's `/opt/packiot/.env` and restart the reader. This is a change on the
     client's factory box (SSM, audited) and needs the user's approval. The bundle writes `.env`
     only if absent, so a later redeploy keeps the new key.
   - After each client: `sparkplug_agent_http_ingest_total{outcome="accepted"}` keeps rising, the
     deprecation WARN for that group stops, and `rejected_auth` / `rejected_key_scope` stay flat.
5. **Turn the shared key off** once `sparkplug_agent_http_ingest_total{outcome="legacy_key"}` has
   stayed flat for a few days: set `AGENT_INGEST_LEGACY_KEY_ALLOWED` to `false` (compose PR) and
   deploy. Rollback = set it back to `true` and redeploy.

## Adding or rotating a key

Generate the new key, add its hash to the map **next to** the old one (both bound to the same
group), `put-secret-value`, restart `sparkplug-agent-shared`, switch the client, then remove the
old hash and restart again. A new client gets its key as part of onboarding.

## Known gaps

- **Onboarding deploy bundle still ships the shared key.** edge-api's reader bundle takes
  `SSM_EDGE_INGEST_KEY` (= the shared `INGEST_API_KEY`). Until edge-api hands out the tenant's own
  key, a newly onboarded box comes up on the shared key, so step 5 must wait for that change (or
  for the box's key to be replaced by hand).
- **ingest-shim** (Incoplast, `:8444`) is not part of this: it admits exactly one group
  (`SCOPE_GROUP`), so its key is already bound to one tenant.
- Production does not run the shared agent yet; apply the same pattern there when it does.
