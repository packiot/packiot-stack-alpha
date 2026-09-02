# Outage Resilience & Offline Operation

What keeps working when a factory loses its internet — and what doesn't. This is
the operator/CS manual view; the *why* lives in ADR-0052 and ADR-0053.

## The one-line model

A factory box reaches the cloud over **HTTPS only** (many client firewalls block
everything else). During an outage, two independent buffers hold the line:

```
PLC counts  →  reader (on the box)  ──[buffer on disk]──▶  cloud   (telemetry)
operator    →  operator tablet (PWA) ─[buffer in browser]─▶ cloud   (actions)
```

Neither loses data; both **replay automatically when the link returns**.

## Telemetry — the reader keeps the counts

The on-box reader polls the PLCs and POSTs the counts to the cloud. If the POST
fails (internet down), the batch is **written to a local disk spool** instead of
dropped, and **replayed oldest-first when connectivity returns** — with its
original timestamps, so the counts land on the right timeline.

- The spool is **bounded** (oldest dropped if an outage runs very long) and
  **survives a box reboot** (it's on disk, not in memory).
- Transient hiccups (a flaky DNS moment) are retried in place; only real failures
  spool. See the reader on the box: `/opt/packiot/reader.py`, spool at
  `/var/lib/packiot/spool`.
- **You don't lose production counts to an outage.** You lose only *timing
  resolution* inside the gap (the counts replay, but as one catch-up burst).

## Operator actions — the tablet keeps the edits

The operator screen is a **PWA** with a durable offline write queue (flag
`VITE_PO_WRITE_QUEUE_ENABLED`). Offline, an operator action is **saved in the
tablet's storage** and **replayed on reconnect**, in order, exactly once.

**Works offline (queued + replayed):** start / stop / pause / finish a PO,
downtime justification, event edits, and switching to an existing job. Each is
**idempotent** (a double-reconnect never double-applies) and **order-preserving**
(a PO's start replays before its stop). A replay that would clash with newer
server state is **parked for review**, never silently overwritten.

**Reads offline:** the screen shows the **last-known** numbers from its cache
(service worker), so the operator isn't blind — but the values are as of the last
successful sync, not live.

### The one action that's different

Creating a **brand-new** production order needs a server-assigned id, so offline it
is **queued** but its follow-on "switch to it" step is **deferred** — the operator
sees *"Order queued — created when the connection returns."* All existing-PO
transitions queue normally. (A fully-atomic offline create-and-replace is a
tracked follow-up.)

## What is NOT available offline (today)

- **Live production numbers / OEE on the *product/operator* screens** — front4 and
  the operator SPA read cloud data *after* the message bus, so offline **those**
  screens show last-known, not live. True live offline reads need an on-box decode +
  local store — a per-client **"fat edge"** decision, **not on by default**. That
  fat edge now ships (opt-in): see
  **[On-Prem Offline Operation](11-on-prem-offline-operation.md)**, which puts a
  *separate*, self-contained dashboard on the box (`:8080`) serving live counts off
  an on-box cache during an outage. A further opt-in — **[the Edge-Operator](12-edge-operator.md)**
  (ADR-0054) — runs the *operator SPA itself* on the box, so the operator screen serves
  reads from a local cache (stale-on-outage, not blank) and buffers writes in a shared
  box-resident outbox that forwards to the cloud on reconnect — rather than each tablet
  buffering on its own.
- **Anything that needs a fresh server id** at the moment of the action (see above).

## Onboarding note — this is per box, automatic

The reader bundle the onboarding **Deploy** step pushes already includes the spool;
the operator's queue is on by build flag. There is nothing an operator or CS
engineer toggles per outage — buffering is the default posture. The only knob is
whether a specific client warrants the heavier on-box decode for live offline reads
(rare; decided per client) — that is the opt-in **"Enable on-prem offline
operation"** toggle, detailed on
**[On-Prem Offline Operation](11-on-prem-offline-operation.md)**.

## Quick reference

| Question | Answer |
|---|---|
| Do we lose counts in an outage? | No — reader spools + replays them. |
| Can the operator keep working? | Yes — PO transitions + downtimes queue + replay. |
| Can they *see* live numbers offline? | On the product/operator screens: no — last-known only (cache). On a box with the opt-in [on-prem fat edge](11-on-prem-offline-operation.md): yes — a local dashboard serves live counts. |
| Create a new PO offline? | Queued; the switch-to-it completes on reconnect. |
| Does a double-reconnect double-apply? | No — every queued action is idempotent. |
| What if the outage is very long? | Counts spool up to a cap (oldest dropped); actions persist on the device. |

See also: [On-Prem Offline Operation](11-on-prem-offline-operation.md) ·
[Edge & Data Ingestion](04-edge-and-ingestion.md) ·
[Cloud Services & OEE](05-cloud-services-and-oee.md) ·
[Frontends, Infra & Auth](07-frontends-infra-auth.md).
