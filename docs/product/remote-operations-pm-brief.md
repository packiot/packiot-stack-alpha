# Remote Operations: Product Brief

**Audience:** Product, Customer Success, Sales, Customer-facing decision makers
**Sister engineering doc:** [ADR-0007](../adr/0007-frontend-write-topology.md) (for the engineering team)
**Status:** **DEFERRED** — was Proposal; parked 2026-06-30. See note below.
**Date:** 2026-06-29

> *Translation note for the non-technical reader: words in italics are jargon we've translated below. Everything else is intentional plain English.*

---

## DEFERRED — 2026-06-30

The internet-outage tolerance initiative this brief was prepared for has been parked. The team's current judgment is that the cost of building offline-tolerant operator workflows is not yet justified by the observed customer pain. No PM decisions are required at this time.

This brief is preserved as **future-revivable material**. If the initiative is revived, the 5 business decisions listed below remain the right product questions to answer.

**Watch for revival signals**: recurring customer complaints about lost operator actions during connectivity blips, new customer in a connectivity-challenged geography, or compliance asks for guaranteed-execution.

---

## 1. The story in one paragraph

Today, every operator action — justifying a downtime, starting a production order, scanning a box — has to reach our cloud servers to succeed. **When the factory loses internet, operators can't do their job.** OEE numbers go wrong, boxes don't get counted, and the customer's shift report is incomplete. We're proposing a change that lets the factory keep working even during outages, AND lets non-factory staff (customer admins, our CS team) take action on a specific factory's data from anywhere. The trade-off is that those remote actions become slightly delayed (seconds to minutes) instead of instant, which the user interface will reflect honestly.

---

## 2. Why this matters (customer impact today)

| What happens during an internet outage today | Customer impact |
|---|---|
| Operator clicks "justify event" → 500 error | Downtime stays unattributed forever; OEE wrong |
| Operator clicks "start PO" → spins, eventually times out | PO start time wrong in records; line operator has to keep notes on paper |
| Box scanner sends count → vanishes | Production count is short; customer thinks line was slower than reality |
| Manager at corporate tries to fix anything for that factory | Can't reach factory at all; has to call someone on-site |

We have no visibility into how often this happens (it's not metered today). Customer support tickets that look like "OEE numbers wrong yesterday" sometimes trace back to a 20-minute internet blip nobody noticed.

**With the change:**
- Factory keeps working through outages of any length.
- All operator actions land cleanly. OEE numbers stay correct.
- Remote actions become possible (from anywhere with internet), executing on the factory when it's reachable.

---

## 3. What changes for users

### Operators on the factory floor
**Nothing visible changes.** Their app works the same way, just doesn't break during outages anymore.

### CS team / regional managers / customer admins (working remotely)
**One new thing to learn:** when they take an action on a specific factory's data from outside that factory, the system shows them a small **"syncing to factory…"** indicator until the factory confirms the change. Usually invisible (under one second). If the factory is offline, they see **"queued — will execute when factory reconnects"** with options to cancel.

This is the same UX pattern as:
- Email "sent" vs "delivered"
- Slack messages with the pending clock icon
- Bank transfers showing "pending" until settlement

Familiar to everyone; no training needed.

### Customer-facing dashboards
**Nothing visible changes.** Same data, same charts.

---

## 4. The business decisions we need product to make

These are the choices ENGINEERING CANNOT MAKE because they're product calls, not technical ones.

### Decision 1 — Which operations are "critical"?

We classify every operator action as either:
- **CRITICAL** → factory keeps it working during outages (more engineering effort)
- **NORMAL** → only works when internet is up (no extra effort)

**Engineering's proposed default rule:**
> *Critical if a 4-hour outage would cost the customer money — lost OEE attribution, missed production count, stuck floor operation.*

Engineering's suggested classification (PM to approve / amend):

| Operation | Suggested | Why |
|---|---|---|
| Justify a downtime event | **Critical** | OEE attribution gets stuck forever if missed |
| Start / pause / resume / stop a PO | **Critical** | Timestamps are wrong if delayed; floor decisions can't wait |
| Edit or split an event | **Critical** | Same as justify — OEE math depends on it |
| Box scan (production count) | **Critical** | Direct production-count integrity |
| Manual downtime entry | **Critical** | Same reasoning |
| Sample tracking | **Critical** | Quality records |
| Create/edit enterprise/site/area/equipment | Normal | Setup happens from corporate, infrequent |
| Manage shifts / shift catalog | Normal | Done ahead of time, not on the floor |
| Manage downtime category list | Normal | Catalog management, not floor-time |
| User and role management | Normal | Done from corporate |
| Generate reports | Normal | Pure read; cloud-only |

**Question for PM**: any operations on the "Normal" list that customers will argue should be "Critical"? Promotion costs engineering effort; demotion saves it.

#### Concrete first-pass classification (all 66 edge-api endpoints)

Engineering audited the current `edge-api` codebase (2026-06-29). Reads (`GET`s) are never "critical" because they're not writes — they just read whatever DB is available. The table below covers only writes, grouped by domain.

> **Notation:** ✅ = engineering recommends CRITICAL; ⚪ = engineering recommends NORMAL. Reads are listed below the table for completeness but require no PM decision.

##### Operator floor-time writes — engineering recommends CRITICAL

| Domain | Endpoint | Why critical |
|---|---|---|
| Downtime events | `justify` | OEE attribution; if not recorded, downtime stays unclassified forever |
| Downtime events | `split` | Same — OEE math depends on event boundaries |
| Downtime events | `split-manual-event` | Same |
| Downtime events | `edit-manual-event` | Same |
| Downtime events | `create-manual-event` | Same |
| Downtime events | `delete-manual-event` | Same |
| Downtime events | `upsert` | Catch-all event mutation |
| Production order | `start-production-order` | Start timestamp must be exact; line waits |
| Production order | `stop-production-order` | Stop timestamp must be exact |
| Production order | `create-and-start` | Combined create + start |
| Production order | `change-status-production-order` | Pause/resume timestamps |
| Production order | `change-time-production-order` | Operator correcting times in real-time |
| Production order | `replace-production-order` | Line PO swap |
| Production order | `setup-production-order` | Pre-production setup state |
| Quality samples | `create-sample` | Quality record from the floor |
| Quality samples | `edit-sample` | Same |
| Quality samples | `delete-sample` | Same |

**Subtotal: 17 endpoints engineering proposes as critical.**

##### Configuration writes — engineering recommends NORMAL

| Domain | Endpoint(s) | Why normal |
|---|---|---|
| Enterprises | `create-enterprise`, `edit-enterprise`, `delete-enterprise` | CS Admin onboarding; done from corporate |
| Sites | `create-site`, `edit-site`, `delete-site` | Same |
| Areas | `create-area`, `edit-area`, `delete-area` | Same |
| Equipment | `create-equipment`, `edit-equipment`, `delete-equipment` | Setup task, not floor-time |
| Equipment reasons | `update-equipment-reasons` | Catalog management |
| Lines | (read-only today) | — |
| packml-register | `create-packml-register`, `edit-packml-register`, `delete-packml-register` | SparkPlug topic routing — CS Admin task |
| packml-config | `generate-packml-config` | One-shot config generator |
| Shifts | `create-shift`, `edit-shift`, `delete-shift` | Scheduled ahead of time |
| Shift hours | `create-shift-hour`, `edit-shift-hour`, `delete-shift-hour` | Same |
| Production order | `create-production-order` (without start) | Pre-planned creation, no time pressure |
| Users | `create-user`, `edit-user`, `delete-user` | Corporate function |
| User roles | `create-user-role`, `edit-user-role`, `delete-user-role` | Same |

**Subtotal: 26 endpoints engineering proposes as normal.**

##### Reads (no PM decision needed)

| Domain | Endpoints |
|---|---|
| Downtime events | `get-justified-downtimes`, `get-pending-downtimes` |
| Production order | `current-production-order` |
| Lines | `list-lines` |
| Equipment | `list-equipments`, `get-equipment-reasons` |
| Quality samples | `list-samples` |
| packml-register | `list-packml-register` |
| Sites / Areas / Enterprises | `list-sites`, `list-areas`, `list-enterprises` |
| Shifts / Shift hours | `list-shifts`, `list-shift-hours` |
| Users / User roles | `list-users`, `get-user`, `list-user-roles`, `get-user-role` |
| Misc | `list-labels`, `get-pages` |

**Subtotal: 23 read endpoints (reads route per the read-tier strategy in section 3, not relevant to this classification).**

##### Borderline cases worth PM discussion

These three are the only ones where engineering's recommendation is genuinely uncertain — your call shapes the trade-off:

| Endpoint | Engineering's suggestion | The trade-off |
|---|---|---|
| `create-production-order` (without start) | NORMAL | Most POs are planned ahead by CS. **But**: some customers create on-the-fly from the floor. If those customers exist, promote to CRITICAL. |
| `update-equipment-reasons` | NORMAL | Catalog change, infrequent. **But**: if a customer's operator workflow involves dynamically adding reason codes mid-shift, promote to CRITICAL. |
| `replace-production-order` | CRITICAL | Floor operator swaps POs mid-line. **But**: if your customers ONLY swap POs via planning tools, demote to NORMAL. |

##### Total tally

- 17 critical writes (operator floor-time)
- 26 normal writes (configuration / corporate)
- 23 reads (handled separately)
- **66 total controllers** in current edge-api codebase

The 17 critical writes is the engineering effort multiplier — each one needs idempotent-handler validation + DLQ-tested error paths. PM ratification of this list is the gate before Phase 1 starts.

### Decision 2 — How long should we queue offline writes?

When a factory is offline and a remote user submits a critical action, we hold the intent in a queue. How long do we hold it before giving up?

| Option | When intent expires | Pros | Cons |
|---|---|---|---|
| **24h** (recommended starting point) | After 1 day | Most outages resolve within 24h | Long enough for weekend outages |
| 1 week | After 7 days | Survives extended downtime | Stale intents become weird to manage |
| Forever | Never | Conservative | Queues grow unbounded; old intents become surprise applications |

**Recommendation:** start at 24h, expose configurable per-customer if needed.

### Decision 3 — Who can override an operator's action remotely?

The new architecture lets a remote user (a CS engineer, a customer admin) initiate writes that apply to a specific factory. Should there be guardrails?

| Scenario | Recommended rule | Rationale |
|---|---|---|
| CS engineer fixes a stuck event from a support ticket | **Allowed**, audit-logged | Support function |
| Customer admin at corporate starts a PO at one of their factories | **Allowed**, audit-logged | Customer's own data; legitimate use case |
| Remote user MODIFIES an action while the local operator is in the middle of the same workflow | **Blocked** with conflict message: "Operator is currently editing this — wait or coordinate" | Avoid stomping on floor staff |
| Anonymous/external write | **Blocked** | Standard auth requirement |

**Question for PM**: should there be a "kiosk mode" preference where the factory can OPT OUT of receiving remote intents at all? Some customers may want air-gapped operations.

### Decision 4 — How visible should the "syncing" state be?

The UI has to communicate write state honestly. How prominent?

| Approach | Description | When chosen |
|---|---|---|
| **Subtle inline badge** (recommended) | Small spinner + "syncing" text next to the affected row, fades on confirm | Trust the user; quiet UX |
| **Modal dialog** | Block the user until confirmed, with cancel option | Higher-stakes operations |
| **Toast notification** | Floating "syncing… confirmed" notification at screen corner | Middle ground |

**Recommendation:** subtle inline for most operations; modal only for the highest-stakes (emergency stop, customer-wide config). PM to confirm tolerance for queued operations being "fire and forget" without confirmation.

### Decision 5 — Should we charge a premium for "guaranteed offline operation"?

This is a real differentiator vs competitors (PI System and Ignition have it; cloud-only OEE platforms don't). Possible pricing angles:

- **Bundled** — included in all tiers, sold as a quality bar ("factory-resilient OEE")
- **Premium tier feature** — only in the highest tier; charge extra per factory
- **Per-factory add-on** — opt-in, $X/month/factory

**Sales/PM call.** Engineering's only input: cost is per-factory infrastructure, not per-operation, so per-factory pricing matches our cost model.

---

## 5. Steps + timeline

**Total engineering effort: ~3–4 weeks for one platform engineer (or split across two).**

| Phase | Engineering work | What product/CS sees | Customer-visible? |
|---|---|---|---|
| 1 | Classify endpoints, ratify CRITICAL list | Approval cycle with PM | No |
| 2 | Build cloud-side router | None | No |
| 3 | Build factory-side drainer | None (one factory at a time) | No |
| 4 | Build the SPA "syncing" UX | UX review cycle | Yes — new badge appears in some flows |
| 5 | Observability + drill | Quarterly outage drill | No |

**Prerequisite:** ADR-0001 (local factory database with replication) — that's a separate but related engineering project. ADR-0007 (this one) only delivers value if ADR-0001 is in place.

---

## 6. Risks and how engineering will manage them

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Remote user's queued intent surprises an on-site operator ("I thought I started the PO but it didn't show up for 10 min") | Medium | Confusion, possibly OEE error | UX makes queued state explicit; SSE updates the remote user when their action lands |
| Factory queue grows unbounded during long outage | Medium | Disk fills, factory paralyzes | Configurable queue depth limit + auto-redirect to DLQ + monitoring alarm |
| Two-write conflict (operator + remote manager edit same PO) | Low-Medium | Last-writer-wins is wrong | Optimistic locking — conflict surfaces as "please refresh" to remote user |
| Customer hates the "syncing" badge | Low | UX pushback | Customer-configurable: hide badge entirely if customer opts out (we still log internally) |
| Engineering ships a critical-path change to cloud before factory | Low | Path 404s on factory | Deployment ordering rule, enforced by drill; also: feature flag system already in place |

---

## 7. What success looks like (metrics product can track)

Three KPIs we'd ship dashboards for, visible to product + CS:

1. **Outage-tolerance ratio** — % of operator actions during periods of cloud-unreachability that succeeded locally. Target: 99.5%.
2. **Remote intent fulfillment time** — p50 / p99 time from "remote user submits action" → "factory confirms applied". Target: p50 < 2s, p99 < 30s during normal operation.
3. **Stuck intents per week** — count of intents that hit DLQ (failed >5 times) per factory. Target: 0 most weeks; investigation trigger if >0 for 3 consecutive weeks at the same factory.

---

## 8. Competitive context

| Vendor | Has offline-tolerant factory operations? | Notes |
|---|---|---|
| OSIsoft PI System | Yes — "Interface Buffering" | Industry incumbent; oldest version of this pattern; on-prem historian |
| Inductive Automation Ignition | Yes — "Store and forward" | First-class feature in their PLC pipeline |
| Cloud-only OEE platforms (most newer entrants) | No | Cloud outage = customer outage |
| Packiot today | No | What this proposal changes |

This proposal puts us at parity with the industrial incumbents on outage tolerance, while keeping the modern cloud architecture's advantages (multi-factory aggregation, one-frontend-for-everything, cloud-side BI).

---

## 9. The PM's decision checklist

Before engineering starts work, we need ratified answers to:

- [ ] **Critical-paths classification approved** (Section 4 / Decision 1)
- [ ] **Queue retention window chosen** (Section 4 / Decision 2)
- [ ] **Remote-write authorization rules confirmed** (Section 4 / Decision 3, including air-gap opt-out)
- [ ] **UX prominence chosen for syncing state** (Section 4 / Decision 4)
- [ ] **Pricing/packaging decision** (Section 4 / Decision 5) — can defer if we ship as bundled-by-default
- [ ] **Naming for the customer-facing badge** ("Syncing…" / "Queued" / something else) — naming is product's domain

---

## 10. Open questions worth a follow-up meeting

- Do we want to surface "this action is queued because factory X is offline" in the customer's main dashboard as a status indicator? (Visibility into infrastructure health = trust signal OR scary noise — depends on customer maturity.)
- Should CS get a "intent intervention" tool — ability to cancel/replay/reorder queued intents for a customer's factory? Operationally useful but powerful.
- Is there a security review needed for the "remote user takes action on factory's authoritative data" capability? Likely yes; this is a meaningful expansion of who can write to a factory's records.

---

## Glossary

- **Cloud DB** — the central database serving all our customers (currently TimescaleDB on AWS).
- **Factory DB** — a new database we'd run on each factory's local computer (per ADR-0001). Stores everything the factory generates, replicates to the cloud DB when internet is available.
- **Intent** — a saved record of "this user wants this action done", queued for delivery to the factory. The factory executes the intent and reports back.
- **Replication** — automatic copying of data between databases. In our case, factory→cloud (events flow up) and cloud→factory (config flows down).
- **Idempotency key** — a unique ID attached to each write so we can safely retry it without applying twice. Standard pattern; same as Stripe payments.
- **DLQ (Dead Letter Queue)** — where failed messages go after we've given up retrying. Engineering checks these regularly; usually means a bug or genuinely-broken state.
- **SSE (Server-Sent Events)** — a way for the user's browser to receive updates from our servers as they happen (used for the "syncing → confirmed" notification).

---

*Questions or feedback: bring to the next product/engineering sync.*
