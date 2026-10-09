# RabbitMQ topology (staging) — canonical reference

The staging broker's queue set is **derived from code**, not hand-created. This doc is
the reference for the canonical topology and the 2026-09-14 cleanup that removed queue
sprawl (44 → 14 queues).

## Single source of truth: `WORKER_TENANT_ALLOWLIST`

`stream-engine` declares its consumer queues from `WORKER_TENANT_ALLOWLIST` (an env in
`compose.staging.yml`). Whatever tenants are in that list get a canonical queue set; nothing
else should exist. Current value:

```
WORKER_TENANT_ALLOWLIST=cpack,sbxcpack,bispharmastaging,incoplast
```

`incoplast` (added 2026-10-09) is the routing key ingest-shim publishes under
(`sparkplug.data.incoplast`). Do not set this variable in `/opt/packiot/.env`: a hand-set
value silently overrides this default.

**Rule:** the tenant token is the **SparkPlug group name, lowercased** (e.g. group
`BISPHARMASTAGING` → `bispharmastaging`). Use exactly one spelling per tenant — do NOT
introduce `_staging` / non-`staging` variants (that drift is what created the sprawl below).

## Canonical per-tenant queue set

For each allowlist tenant `<t>`, exactly three queues (competing-consumer + dead-letter):

| Queue | Purpose |
|---|---|
| `stream-engine-q-<t>` | live consumer queue (bound to exchange `oee`, routing key `sparkplug.data.<t>`) |
| `stream-engine-q-<t>-retry-30s` | retry (30s TTL → back to main) |
| `stream-engine-q-<t>-failed` | dead-letter (poison messages) |

Plus the shared infrastructure (keep):

- `stream-engine-q` (+ `-retry-30s`, `-failed`) — the base/default worker queue (bound to `oee`/`sparkplug.data`)
- `oeecloud-fanout-cpack-to-sbxcpack` — the CPACK→sandbox fanout
- `oee-unroutable-q` — catches messages that match no `oee` binding (alternate exchange via
  policy `oee-ae`). Capped by policy `oee-unroutable-cap`: 50,000 messages, 14-day TTL.
  Any depth fires `OeeUnroutableMessages`, so it must stay empty in normal operation.
- `e2efixture-sink-q` — bound to `oee` / `sparkplug.data.e2efixture`. The deploy's synthetic
  counter fixture (group `E2EFIXTURE`) lands here, not in `oee-unroutable-q`. Capped by policy
  `e2efixture-sink-cap`: 200 messages, 1-day TTL. Nothing consumes it.
- Exchanges: `oee` (topic), `oee-retry` (topic), `oee-failed` (topic), `oee-unroutable` (fanout)

→ 18 queues total for the current 4-tenant allowlist (3 per tenant + 6 shared).

## 2026-09-14 cleanup (44 → 14)

Removed **30 orphan queues** — 10 dead/legacy tenants × {base, `-retry-30s`, `-failed`}.
Every one was proven dead before deletion: **0 consumers, 0 messages, and
`message_stats.publish = 0` (never received a single message in its lifetime)**, and none
was in `WORKER_TENANT_ALLOWLIST` (so stream-engine will not re-declare them):

`bisnago`, `bisnago_staging`, `bispharma`, `bispharma_staging`, `dummyonb`, `incoplast`,
`incoplast_staging`, `ops_test`, `simcorp`, `staging`.

Note the drift these encoded: **Bispharma had three name variants** — `bispharma`,
`bispharma_staging`, and the live `bispharmastaging` — only the last is real. Same class of
`_staging` drift for `bisnago`/`incoplast`.

## Preventing recurrence

1. Onboarding must add the tenant to `WORKER_TENANT_ALLOWLIST` using the canonical
   lowercased SparkPlug group name — never a hand-created queue, never a name variant.
2. A queue with 0 lifetime publishes and no allowlist entry is garbage — safe to delete
   with `DELETE /api/queues/%2F/<name>?if-empty=true&if-unused=true`.
3. Connections should stay few (one per live service: stream-engine, sparkplug-decoder,
   oeecloud-fanout, superset-worker) — a spike in connections signals a leak.
