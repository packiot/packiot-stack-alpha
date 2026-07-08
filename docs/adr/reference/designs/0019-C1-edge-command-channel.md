# C1 — Edge command channel (ADR-0019 G4)

The one genuinely new component in the stack. Everything else is data flowing
*out* of the factory (machine → cloud). This is the return path: an operator action
in the cloud/edge that writes a value *down to the PLC*. Incoplast's local UI does
this today (`Send_Parameter`, `change PO PackML` push through SparkPlug to the
controller); our operator SPA cannot, and that gap is the only thing blocking C3.

> **Status**: design (2026-07-08). Implementation validates post-flip against the
> live Incoplast tenant — a command path has no meaning without a machine (or the
> plc-sim standing in for one) to receive it.

## The shape: the ingest path, reversed

The transformer already owns the PLC session for ingest. The command channel reuses
that ownership in reverse, over the same broker:

```
  operator action (SPA / local UI)
        │  POST /api/commands/<verb>   (edge-api, authorized)
        ▼
  edge-api ──publish──▶ RabbitMQ topic  edge.commands.<tenant>
        │  (+ user_logs audit entry — same contract as every operator action)
        ▼
  edge-transformer  ──subscribe edge.commands.<tenant>──▶  translate → PLC write
        │                                                    (SparkPlug DCMD / S7 write)
        └── result ──▶ edge.commands.<tenant>.ack  (delivered / rejected)
```

## Contract

**edge-api — the command producer.**
- `POST /api/commands/po-setup`, `POST /api/commands/param-write` (the verbs are
  `capabilities.commands.allowed` from the descriptor — an endpoint for a verb the
  tenant hasn't enabled returns 403).
- Body: `{ idEquipment, packmlTopic, verb, params: {...} }`. Publishes a typed
  envelope to `edge.commands.<tenant>` with **publisher confirms** (a command must be
  accepted by the broker or the caller gets an error — never fire-and-forget).
- Writes a `user_logs` entry (`eventType: 'command-issued'`) — commands are operator
  actions and belong in the audit trail like PO starts. **They must NOT be replayed**
  by the mirror workers (a replayed PLC write is dangerous) — use a non-replayed
  eventType, verified against the replay dispatchers.
- Authorization: the caller's tenant + permissions gate which equipment they may
  command. Server-side, never client-asserted.

**edge-transformer — the command executor.**
- Subscribes `edge.commands.<tenant>` (per-tenant queue, quorum, retry/DLX — the
  existing consumer pattern, inbound).
- Translates the typed verb to the protocol write: SparkPlug **DCMD** (device command)
  for SparkPlug PLCs; an S7/OPC-UA write for those adapters. The translation table is
  the inverse of the ingest normalizer.
- **Idempotent**: a command carries a key; re-delivery does not double-write.
- Publishes an ack to `edge.commands.<tenant>.ack` (or DLXs on repeated failure).
- If the tenant lacks `capabilities.commands.enabled`, the transformer does not even
  subscribe — the capability flag gates the whole path.

## Safety (this writes to physical machines — the discipline is higher)

- **Allow-list only** — a verb not in `capabilities.commands.allowed` is refused at
  both ends. No generic "write any register."
- **Confirms + idempotency end to end** — a command is accepted once or refused; a
  retry never doubles.
- **Full audit** — every command in `user_logs`, attributable to a user.
- **Fail-safe on ambiguity** — if the transformer cannot map a verb to a definite
  PLC write, it rejects (DLX), never guesses. (Contrast the ingest side, which
  fail-soft zero-fills — a *write* must not.)
- **Never replayed** — the mirror workers must ignore the command eventType; a
  replayed PLC write is a physical action taken twice.

## Why it unblocks C3

Our operator SPA can already do everything Incoplast's local UI does *except* push
parameters to the PLC. With this channel, the SPA's PO-setup / parameter screens post
to `/api/commands/*` and reach the machine — full parity with their bespoke UI, which
is what lets [C3](0019-C3-edge-operator-spa.md) replace it.

## Test strategy (post-flip)

The `plc-sim` gains a DCMD listener that echoes commands into its state, so the whole
path is exercised end-to-end against the simulator before any real PLC. The live
Incoplast tenant (Layer A) is the acceptance environment; a real PLC write is the
final factory-side validation (Phase F).
