# 6 — APIs and the Operator

> For a concrete inventory of each API's endpoints, datasets, and the operator's
> screens, see the [Service Catalog (Ch.11)](11-service-catalog.md).

So far the data has flowed one way: machine → cloud → database. This chapter is
about the other direction — how *people* read the results and *act* on the system.
Two kinds of people: the **operator** on the factory floor during a shift, and the
**product user** looking at dashboards in the office. And two kinds of interaction:
**reads** (show me the state) and **writes** (change the state).

The organizing principle, from [Chapter 2](02-architecture-at-a-glance.md), is that
these go to **different services**. That split is the whole design; let's see why it
matters.

## edge-api — the control plane (writes)

`edge-api` (a NestJS service) is where **actions** happen. When an operator starts a
production order, justifies a downtime, splits an event, or an admin onboards a new
site, that request goes to edge-api. It is the only service that changes the world.

Its shape is worth knowing because it enforces a few non-obvious rules:

- **Every mutation writes an audit entry.** Each controller records a `UserLogsDTO`
  into the `user_logs` table. This is not just logging — it is a *live data
  contract*. Two downstream services (the mirror workers, below) *replay* from
  `user_logs`, so the audit trail is load-bearing infrastructure, and renaming an
  event type silently breaks replay.

- **The API never computes OEE.** Per [ADR-0014](../adr/0014-extract-oee-math-from-database-to-app.md),
  math lives in the engine. edge-api records *what the operator did*; the worker
  decides what it *means*. Keeping this boundary clean is why an operator action and
  its OEE consequence can be reasoned about separately.

- **Actions are enumerated, not free-form.** PO lifecycle (start / stop / setup /
  replace / change-status), downtime handling (create / edit / delete / justify /
  split) — a bounded vocabulary, each with a defined effect. Several of these routes
  are *frozen contracts* because the mirror workers POST to them; they cannot change
  shape without coordinating the replay side.

Operator login also lives here now: a `/session` endpoint that verifies a bcrypt
password hash on the `users` table and mints a JWT. This replaced a login that used
to live inside a Node-RED flow with plaintext credentials — a small but real
security upgrade, and part of moving the operator fully onto the standard stack.

## refdata-api — the read plane (reads)

`refdata-api` (a Go service) serves the data the UIs *display*. It exists to replace
a GraphQL layer (Hasura) that sat directly on the database — a layer the migration
is retiring. It offers two surfaces
([ADR-0015](../adr/0015-customer-facing-query-api.md)):

1. **Fixed routes** — a handful of exact endpoints for the operator's needs
   (`/v1/operator-po-list`, `/v1/pending-downtime`, `/v1/events-timeline`, …), each
   a thin wrapper over a database view or function.
2. **A composable query API** — `/v1/catalog` lists datasets, `POST /v1/query` runs
   a `{dataset, filters, window}` request, and an `X-Api-Key` header maps to a
   `customer_id` *server-side* — so a browser can never ask for another tenant's
   data by changing a parameter.

The design tension refactored-away here is *tenancy authority*: in the legacy world,
the browser held an API key and passed its own enterprise id in queries. In the new
world, the read plane resolves identity server-side and the client cannot lie about
who it is.

## The operator SPA — same behavior, cleaner backend

The **operator** is a React single-page app: the screen a floor operator uses during
a shift to see the current order, start the next one, and justify why a machine
stopped. Here is the interesting part for someone learning the stack: **the SPA's
behavior did not change during the rebuild, but everything behind it did.**

Originally, the SPA talked to a "backend-for-frontend" built out of Node-RED flows —
reads resolved through Hasura, writes shaped and forwarded to edge-api, login minted
from flow-config JSON. The rebuild moved every one of those to the standard stack,
one seam at a time, *without the components changing what they display*:

- **Reads** now go to refdata-api (`/v1/*`).
- **Writes** now go to edge-api (`/api/*`), with the enterprise API key injected by
  nginx *server-side* so the browser never holds it.
- **Login** now goes to edge-api's `/session`.

The mechanism that made this safe is a single **client module** (`endpoints.js`):
every backend call became one function, so the cutover was a change of *where each
function points*, not a rewrite of 24 scattered call sites. And the same-origin
nginx proxy means the browser sees one host and never learns there are three
services behind it.

This is the concrete meaning of "same behavior as the client-side prod" you'll hear:
the operator's experience is identical — the same screens, the same actions, the
same payloads — but reads, writes, and auth now flow to purpose-built services
instead of a Node-RED tangle, and the browser no longer carries tenant credentials.

> The full account of this rebuild — the six waves, the contracts, the one live bug
> it fixed along the way (a "create PO" button that silently did nothing) — is
> [ADR-0018](../adr/0018-operator-frontend-integration-makeover.md).

## The mirrors — how staging gets real data

One more pair of services, because they explain how any of the above gets *tested*
against reality. Staging has no real factory attached, so two services feed it from
production. They are easy to confuse, so here is each one's responsibility, exactly:

**mirror-worker-go — the data mirror (and validator).** It replays a real
enterprise's production *data* — production orders, events, value deltas — from the
production database into staging. Its cardinal rule is that it is **read-only on the
production side, always**: it observes prod, it never writes to it. But it does more
than copy. It also *validates*: a reconciler checks that active POs and event
streams line up, a comparator continuously measures how far staging has drifted from
prod (an OEE-divergence percentage), and a dead-letter queue with a reanimator
handles replays that fail. It is a mirror with a conscience — it tells you not just
"here is prod's data" but "here is how faithfully staging is reproducing it."

**shadow-mirror — the action mirror.** It replays *operator actions* — the PO
lifecycle events, downtime justifications, and edits recorded in the `user_logs`
audit trail — onto the shadow flows. Where mirror-worker-go carries the *data plane*
(what the machines did), shadow-mirror carries the *control plane* (what the people
did), so that the shadow flows experience the same operator behavior the real system
did. This is why the `user_logs` audit trail is a live contract and not just logging
([above](#edge-api--the-control-plane-writes)): shadow-mirror reads from it.

Together they make staging behave like a live factory, which is what lets the
[differential bake](04-the-engine.md#proving-it-golden-fixtures-and-the-differential-bake)
compare flows on realistic traffic.

Their fates at the flip differ, and the difference is instructive.
**shadow-mirror is pure migration scaffolding** — once the three flows collapse to
one, there are no "shadow flows" to replay actions onto, so it retires.
**mirror-worker-go stays**, repointed at the single promoted database: even after
the flip, staging has no factory of its own, so it still needs real production data
to be a useful test bed. One is a tool for the migration; the other is permanent
staging infrastructure that the migration merely repoints.

---

Next: [Customizations and Real Factories](07-customizations-and-real-factories.md) —
where the clean architecture meets a messy real-world factory.
