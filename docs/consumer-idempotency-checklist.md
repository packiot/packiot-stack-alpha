# Consumer idempotency — the ADR-0011 reviewer checklist

**Status**: Load-bearing per [ADR-0011](./adr/0011-durability-boundary-and-store-and-forward.md) rule 2.
**Audience**: Every reviewer of every PR touching a message-queue consumer in this repo.

---

## The rule (one sentence)

> **Every consumer must produce the same visible outcome when it processes the same message twice.**

That's it. If the second delivery would double-count a value, insert a duplicate row, send a second email, or over-charge a customer, the consumer is not idempotent, and per ADR-0011 rule 2 the PR should not merge.

---

## Why this matters — the specific scenarios where duplicate delivery happens

Not theoretical. Here are the exact code paths in this stack that DO deliver the same message more than once:

1. **RabbitMQ redelivery on unacked message** — consumer starts processing, crashes, RMQ redelivers to another consumer instance.
2. **DLX retry loop** — [`amqp-dlx-retry-topology`](../../notes/systems/amqp-dlx-retry-topology.md) — after the retry TTL, the message returns to the primary queue.
3. **Reanimator on stuck DLQ rows** — [mirror-worker-go PR #84](https://github.com/packiot/packiot-stack-alpha/pull/84) — resets retry_attempts=0, causes another delivery attempt.
4. **Publisher confirms retry** — ADR-0011 P1 will add retry-on-nack, which means the SAME message may be published to RabbitMQ multiple times if a nack comes in mid-retry.
5. **Manual replay** — ops runs a fixed script that re-publishes archived messages during an incident.

Every one of these is real, has happened in production, and will happen again. Consumers that assume "each message is delivered exactly once" ship bugs.

---

## The pattern that works — business-key deduplication

The canonical fix: pick a **stable business key** on the message, then use it to make the write idempotent.

| Situation | Business key | Idempotent write |
|---|---|---|
| Mirror worker replaying `user_logs` events | `id_user_log` (the source row's primary key) | `INSERT ... ON CONFLICT (id_source_log) DO NOTHING` |
| Equipment event replication | `(equipment_id, ts_event)` composite | `INSERT ... ON CONFLICT DO NOTHING` |
| Production order lifecycle | `(id_enterprise, id_order)` composite | `UPSERT` with checked delta |
| Sparkplug metric write | `(equipment_id, ts_value, parameter)` composite | `INSERT ... ON CONFLICT DO UPDATE` |
| Email send / Slack post | Message ID + destination hash | `SELECT` before send, skip if seen |
| Increment a counter | Not composable — use an accumulator table with the business key as PK, aggregate on read | Insert into events table + read as sum |

Note the last row: **counters are the hardest case**. Naïve `UPDATE counters SET count = count + 1` is *never* idempotent. Store the events, sum them on read (or via a materialized view).

---

## What NOT to use as the idempotency key

- ❌ **RabbitMQ delivery tag** — changes across redeliveries. Only unique within a single consumer session.
- ❌ **RabbitMQ message ID** — set by publisher; if it retries the publish, same key hits the consumer with different content potentially. (Only usable if the publisher CAN'T retry — rare.)
- ❌ **`time.Now()`** — you'll compare against the write's timestamp, which is later.
- ❌ **Auto-increment primary key on the destination side** — every insert gets a new one, defeating the point.
- ❌ **UUIDs generated on receive** — same reason.

The key must come from the **source system's stable identity**, established BEFORE the message was ever sent.

---

## The reviewer checklist — copy this into the PR description

```markdown
## ADR-0011 rule 2 — consumer idempotency

<!-- If this PR adds or modifies a message-queue consumer:  -->

- [ ] What message queue does this consumer read from?
      → 
- [ ] What is the business-key for deduplication?
      → 
- [ ] What database operation makes the write idempotent?
      → (INSERT ... ON CONFLICT / UPSERT / SELECT-then-write / etc.)
- [ ] What happens on duplicate delivery? (Simulate: replay the same message twice, verify state matches after 1 vs 2 deliveries.)
      → 
- [ ] Is there a test covering the duplicate-delivery case?
      → Link to test:
```

If the PR touches a consumer and doesn't complete this checklist, ask for it before approving.

---

## Real examples in this repo

- **mirror-worker-go** (`services/mirror-worker-go/internal/replay/`) — every handler uses `mirror_id_map` PK-lookup + `ON CONFLICT DO NOTHING` inserts on staging tables. Duplicate replays are no-ops.

- **oeecloud-worker** (`services/oeecloud-worker/internal/handlers/`) — writes to `equipment_values` with `UNIQUE(ts_value, id_equipment)` — natural dedup at the DB level.

- **edge-transformer shadow-mode** (`services/edge-transformer/internal/handlers/shadow.go`) — currently a no-op handler. Once Phase 3 lands real transforms, they'll follow the mirror-worker-go pattern.

Read one of those before designing a new consumer. Pattern reuse per ADR-0009 Errata Correction 2 is enforced.

---

## The one-liner senior-engineer test

If you can't answer this question in one sentence about your consumer, it's not idempotent yet:

> *"If this message is delivered twice, what specifically prevents the second delivery from causing a duplicate row / double-count / repeat email?"*

Answers that count:
- "The DB has a UNIQUE constraint on (X, Y) and my INSERT uses ON CONFLICT DO NOTHING."
- "I SELECT by business-key first and skip if the row already exists."
- "The write is a full UPSERT that replaces the row; both deliveries produce the same final state."

Answers that don't count:
- "It'd be really rare for this message to arrive twice." — Not a design; hope isn't idempotency.
- "The publisher won't retry." — Publisher confirms + reanimator + DLX retry guarantee it will, sometime, some day.
- "We'll add a check later." — Later never happens; ADR-0011 rule 2 says now or block the PR.

---

## What this checklist does NOT solve

- **Side effects outside the DB** (email/Slack/webhook out of your process) — those need a `sent_notifications` audit table with the business-key + a `SELECT`-before-send pattern.
- **External APIs** — you may need an idempotency token you send to the API (Stripe's `Idempotency-Key` header is the canonical example).
- **State machines** — "advance from PENDING to RUNNING" is not idempotent unless the transition rules allow "already RUNNING → stay RUNNING".

For each of those, the same idea applies: find a stable key, and make the write / API call check-then-act rather than blind-write.

---

## References

- [ADR-0011](./adr/0011-durability-boundary-and-store-and-forward.md) — the load-bearing rule this checklist enforces
- Stripe: [Building Robust Systems with Idempotency Keys](https://stripe.com/blog/idempotency) — the industry canonical write-up
