# Edge Transformer: Product Brief

**Audience:** Product, Customer Success, Sales, Customer-facing decision makers
**Sister engineering doc:** [ADR-0009](../adr/0009-edge-transformer-go-service-and-nodered-split.md) (for the engineering team)
**Phase 0 evidence:** [edge-nodered customization shapes catalog](../edge-nodered-customization-shapes.md)
**Status:** Proposal — awaiting product decisions before engineering commits
**Date:** 2026-06-30

> *Translation note for the non-technical reader: words in italics are jargon we've translated in the glossary at the bottom. Everything else is intentional plain English.*

---

## 1. The story in one paragraph

Every factory we run today has a *Node-RED* instance — the visual low-code tool our Customer Success engineers use to wire each customer's PLCs and special-snowflake quirks into the platform. It works, but each instance has grown into roughly **1,000 nodes and ~16,000 lines of JavaScript**, more than half of which is just configuration disguised as code. Onboarding a new customer takes days of clicking through Node-RED tabs; production deploys break in surprising ways; performance is bounded by what a single-threaded JavaScript runtime can do. We're proposing to **split the work in two**: keep Node-RED for the genuinely customer-specific low-code tweaks (where the visual editor is a real win for CS), and move all the standardized heavy lifting into a new Go service called *edge-transformer*. New customers will onboard via a **single `client.yaml` file** instead of a thousand-node visual project; existing customers keep their visual editor for the bits that need customizing. Nothing operators see on the floor changes. Nothing customer dashboards show changes. Engineering wins ~10× performance headroom and roughly half the deploy bugs we get from Node-RED today.

---

## 2. Why this matters (business framing)

### Today's reality at every factory

| Dimension | Today | Why it hurts |
|---|---|---|
| Nodes per factory in Node-RED | ~1,000 | Hard to review, hard to diff, slow to load |
| JavaScript in customer-specific tabs | ~16,000 LOC | Mostly config, but indistinguishable from real logic at a glance |
| Config-disguised-as-code | ~9,100 LOC (58% of all JS) | Can't be reviewed, can't be linted, can't be safely diffed |
| Time to onboard a new customer | **Days** | CS engineer clicks through Node-RED tabs, copies & adapts |
| Performance ceiling | Single-threaded JS runtime | One slow customer can degrade message throughput for that whole factory |
| Production deploy failure rate | Multiple incidents/quarter | Node-RED's flow-manager has surprise behaviors (session 64 was a 6-attempt debug saga) |

### After the split

| Dimension | After | Improvement |
|---|---|---|
| Nodes per factory in Node-RED | ~150 | The 58% pure-config is GONE; another big chunk moves to Go |
| Lines of code per customer | ~6,700 LOC of actual logic + 1 YAML file | Logic is the real signal; config is a diffable file |
| Time to onboard a new customer | **A few hours** | Engineer writes `client.yaml`, points at PLC endpoints, done |
| Performance ceiling | ~10× headroom | Go handles concurrent load; multi-core; lock-free where possible |
| Production deploy failure rate | Roughly half | Removes Node-RED flow-manager from the standardized hot path |

The two numbers worth committing to memory:

- **Onboarding: days → hours.** Direct, measurable Sales/CS win.
- **Per-factory throughput: ~10× headroom.** Buys us multi-year growth on existing hardware.

The catalog backing these numbers is in the [Phase 0 customization shapes doc](../edge-nodered-customization-shapes.md), derived from one real customer's Node-RED instance (C-Pack Solutions, Montreal site).

---

## 3. What changes for users

### Operators on the factory floor
**Nothing visible changes.** Their app works exactly the same way. (The factory might run slightly faster under heavy load.)

### Customer-facing dashboards
**Nothing visible changes.** Same data, same charts, same OEE numbers.

### CS engineers maintaining customer instances
The CS team is the only audience whose tools actually change. Here's the swap:

| What CS does today | What CS does after the migration |
|---|---|
| Click through ~1,000 Node-RED nodes per customer | Edit ~150 Node-RED nodes per customer |
| Edit ~9,100 lines of JS that's actually config (in giant `function` nodes) | Edit a `client.yaml` file with proper structure + IDE autocomplete |
| Hand-wire 37 OPC-UA tag mappings per customer in Node-RED | Add 37 entries under `equipment_mapping:` in YAML |
| Maintain shift/time math in JavaScript per-customer | Nothing — moved to standardized Go library |
| Make giant data-table function nodes | **Not allowed anymore.** Data tables go in YAML files. |
| Hardcode URLs and secrets inside function nodes | URLs and secrets in YAML with `${ENV_VAR}` syntax |
| Build per-equipment state machines in Node-RED subflows | **Same.** This is what Node-RED is FOR — keep it. |
| Visually route messages with switch/change nodes | **Same.** Visual routing stays in Node-RED. |
| Build customer-specific payload transforms | **Same.** Customer-specific transforms stay in Node-RED. |

**Translation for non-technical readers:** CS keeps their familiar visual editor for the things that genuinely need flexibility per customer. They lose the ability to write giant blobs of data inside Node-RED — which is actually a productivity gain, because those blobs become a proper file that's diffable, reviewable, and version-controlled.

A populated example of the new `client.yaml` for the C-Pack customer is here: [`docs/clients/cpack.example.yaml`](../clients/cpack.example.yaml).

### Customer admins editing things themselves
Out of scope for this brief. Customers don't touch Node-RED today and won't touch the new tools. Discussed under Decision 2 below.

---

## 4. The business decisions we need product to make

These are choices ENGINEERING CANNOT MAKE because they're product calls, not technical ones.

### Decision 1 — Governance rules for customization tabs

Engineering's audit of one real customer found 155 function nodes ranging from 5 lines to 8,113 lines. The 8,113-line monster was the worst, but we also saw 18 functions in the 100–300 LOC range that mix logic and data freely. Going forward we want rules.

**Engineering's proposed defaults** (PM to approve or amend):

| Rule | Proposed limit | Why |
|---|---|---|
| Max LOC per function node | **150 LOC** | P90 of observed real functions; 90% of legitimate work fits |
| Max functions per customization tab | **30** | Keeps a tab reviewable in one sitting |
| Big data structures (>20 lines of JSON literal) | **Banned** | Must go in `data_tables:` YAML instead |
| Hardcoded URLs / API keys | **Banned** | Must come from YAML via `${ENV_VAR}` |
| HTTP request nodes for cloud APIs | **Banned** | Must go through configured `integrations:` |
| `flow.set` / `global.set` of objects >1 KB | **Banned** | Indicates config-disguised-as-code |
| Calling external npm packages from function nodes | **Banned** | Anything that needs a library is engineering's job, not CS's |

**The trade-off:** stricter rules = more onboarding friction for CS, but cleaner long-term ops. Looser rules = familiar to current CS, but we end up back where we started in 18 months.

**Question for PM:** are these defaults too strict? Too lax? CS team should weigh in before we lock them.

### Decision 2 — Who owns customization flows after migration?

Today, the CS team owns every customer's Node-RED instance. After the split, the customization surface shrinks dramatically (~150 nodes vs ~1,000). Three ownership models:

| Model | Description | Pros | Cons |
|---|---|---|---|
| **CS owns it** (today's model) | CS team makes all changes per customer | Familiar; no customer enablement needed | Bottleneck on CS; no self-service |
| **Customer owns it, eng review required** | Customer's IT team writes flows; we review before deploy | Customer empowerment; CS scales | Need to ship customer-facing tooling; security review |
| **Hybrid** (recommended starting point) | CS owns by default; large/sophisticated customers (e.g. CPack's internal team) can opt-in to ownership | Maximum flexibility | More processes to maintain |

**Engineering's note:** the new `client.yaml` is a file in a Git repo. We already have the multi-tenant access patterns for this from `api-gitops`. The "customer self-service" lever exists technically; product decides if/when to pull it.

**Question for PM:** do we want to pitch self-service customization as a customer feature, or keep it CS-only as a stability differentiator?

### Decision 3 — Rollout cadence

Engineering can ship the new edge-transformer with feature flags so we migrate factory-by-factory at whatever pace the business wants. Options:

| Option | Description | Risk profile |
|---|---|---|
| **Pilot then progressive** (recommended) | One pilot factory for 2 weeks, then 2 factories/week until all migrated | Low risk; long calendar time (~3 months for all customers) |
| **Big-bang per customer** | One customer fully cuts over at once (multiple factories same day) | Medium risk; mid calendar time |
| **All factories at once when ready** | Wait until the new path is bulletproof, then mass-migration weekend | High risk; shortest calendar time |
| **New customers only** | Existing factories stay on old Node-RED forever; only new sales use the new path | Lowest risk; permanently maintains two stacks (operational debt) |

**Engineering's recommendation:** pilot-then-progressive. The pilot should be CPack (we already know the shape of their data; they have technical staff who can give us a real signal).

**Question for PM:** is "3 months calendar time to fully migrate" acceptable, or does Sales need a faster cutover for some customer's renewal cycle?

### Decision 4 — Existing customers: proactive vs reactive migration

Independent of cadence (Decision 3), do we migrate existing customers proactively, or only when they ask for changes anyway?

| Approach | Description | Pros | Cons |
|---|---|---|---|
| **Proactive** | We plan + migrate every existing customer on a schedule, regardless of whether they've asked | Consistent stack across all customers; CS only has to maintain ONE thing | Requires customer coordination for downtime windows; some customers will say "don't touch what's working" |
| **Reactive** | Existing customers stay on Node-RED-only until their next CS engagement (PLC swap, new line, etc.); we migrate during that engagement | No customer disruption | Permanent dual-stack period; some customers may stay on old path for years |
| **Sunset date** (recommended) | Reactive in the first 6 months; then announce a sunset date 12 months out for the old path | Best of both worlds; gives Sales a story | Requires committing to a date we can't easily push |

**Question for PM:** what's the appetite for customer-impacting maintenance? "Zero" is a valid answer and pushes us to reactive.

### Decision 5 — Pricing and packaging

The new architecture creates a sellable story: **"Onboard your factory in hours, not days."** Three possible angles:

| Angle | Pitch | Risk |
|---|---|---|
| **Bundled** (no price change) | Treat as quality-of-service improvement; all tiers benefit | Easy; leaves money on the table |
| **Differentiator for Sales** | New customers see "rapid onboarding" as a headline feature vs competitors | No new revenue; better win rate |
| **Premium tier feature** | "White-glove onboarding in 24 hours" only on top tier | Genuine ARPU lift; risk of being seen as a take-away from lower tiers |
| **Per-customer onboarding fee waiver** | Charge a one-time onboarding fee on legacy path; waive it on the new path | Margin protection; clear migration incentive |

**Engineering's only input:** the cost-per-customer of the new path is LOWER, not higher. So this is purely a packaging/positioning call — no cost-floor constraint.

**Question for PM/Sales:** is rapid onboarding a feature buyers will pay extra for, or is it pure competitive table-stakes?

---

## 5. Steps + timeline

**Total engineering effort:** ~8–10 weeks for one platform engineer (or 5–6 weeks split across two).

| Phase | Engineering work | What product/CS sees | Customer-visible? |
|---|---|---|---|
| 0 | Catalog real customer shapes (DONE) | Phase 0 doc delivered 2026-06-30 | No |
| 1 | Schema design + example YAML (DONE) | `_schema.yaml` + `cpack.example.yaml` delivered | No |
| 2 | Build edge-transformer Go service (skeleton) | Architecture review with PM | No |
| 3 | Port standardized logic (PLC normalization, time/shift math) to Go | None | No |
| 4 | Build YAML loader + Node-RED config generator | CS tooling preview | No |
| 5 | Pilot factory cutover (CPack Montreal) | First customer migration; week-long bake | Yes — pilot only |
| 6 | Progressive rollout per Decision 3 | Per-factory migrations on agreed cadence | Yes — one factory at a time |
| 7 | Governance enforcement + CS training | CS training session; lint rules live | No |

**Prerequisites:**
- None hard. The new path can run alongside the old path on any factory.
- ADR-0004 (centralized client config) is a sister proposal; if it lands first, edge-transformer reuses its scaffolding. If not, edge-transformer ships its own loader and ADR-0004 absorbs it later.

---

## 6. Risks and how engineering will manage them

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| CS pushback on losing `flow.set` freedom | Medium | Slows migration; perception of "engineering taking away CS tools" | Run a CS workshop in Phase 4; ship the governance rules WITH the YAML schema so they see what's gained, not just what's restricted; CPack pilot proves the win |
| Schema-version drift across customers | Medium | Some customers on v1, others on v1.2; CS confusion | `schema_version:` field is REQUIRED in every `client.yaml`; auto-migration scripts on version bumps; existing customers pinned until explicitly upgraded |
| Customer-specific Node-RED tweak doesn't fit any of the 8 shapes | Medium | Forces an unplanned shape-9 addition; schema grows | Phase 0 catalog covers 1 customer; Phase 5 pilot covers a second (CPack ≠ original). Phase 0.5 (audit 2 more customers' flows) is cheap insurance — recommended before Phase 3 |
| Performance regression on edge cases (unusual PLC) | Low | One customer slower than today | Pilot phase IS the catch net; rollout to second customer waits on pilot's metrics |
| CS team needs significant retraining time | Medium | 2–3 weeks lost productivity during transition | Side-by-side cheat-sheet ("how I used to do X in Node-RED → how I do X now in YAML"); video walkthrough; pair-program first 3 customer migrations with engineering |
| The Go service has a bug that takes down a factory | Low | One factory outage | Same DLQ + retry topology we already proved out in mirror-worker-go (session 67+68); old Node-RED path stays warm for 30 days post-migration as instant rollback |

---

## 7. What success looks like

Three KPIs we'd ship dashboards for, visible to Product, Sales, and CS:

1. **Time to onboard a new factory** — from "kickoff call" to "first OEE numbers flowing in cloud DB". Current baseline: ~3–5 days. Target after migration: **under 8 hours** for a new customer who already has PLC connectivity sorted; under 2 days for a fully new install.

2. **Per-factory message throughput headroom** — peak sustained messages/second per factory before queue depth grows. Current baseline (Node-RED, single-threaded): ~50 msg/s sustained on the busiest customer (CPack). Target after migration: **~500 msg/s sustained** with the same hardware, validated under load test before pilot cutover.

3. **Production deploy success rate** — % of deploys to a factory that don't require engineering intervention. Current baseline: ~85% (Node-RED flow-manager bugs, config drift, schema mismatches). Target after migration: **>95%**, measured monthly.

---

## 8. Competitive context

| Vendor | Equivalent capability | How they compare |
|---|---|---|
| **OSIsoft PI System** | PI AF (Asset Framework) for config; PI Interface configs for PLC mapping | Mature config-driven model. Heavy, enterprise-only, expensive. We end up roughly comparable on onboarding speed, dramatically lighter weight |
| **Inductive Automation Ignition** | Designer + script editor + tag browser | Strong low-code story BUT all customization sits inside one tool; no clean separation between config and logic. We come out cleaner |
| **Cloud-only OEE platforms** (newer entrants — Tulip, Worximity) | Visual flow-only, sometimes drag-drop tag bindings | Looks great in demos; falls over on customer-specific PLC quirks. Our hybrid (low-code WHERE NEEDED + config-driven WHERE STANDARD) is the differentiator |
| **Packiot today** | Node-RED only, no separation | What this proposal changes |
| **Packiot after this proposal** | Node-RED + edge-transformer + client.yaml | Matches PI's onboarding speed at ~1/10th the deployment weight; beats Ignition on review/diff-ability; beats cloud-only on PLC flexibility |

The sentence to remember: **we get PI-class onboarding speed with Ignition-class customer flexibility, at our existing cost structure.**

---

## 9. The PM's decision checklist

Before engineering starts Phase 2 (Go service build), we need ratified answers to:

- [ ] **Governance rules approved** (Section 4 / Decision 1) — max LOC, banned patterns
- [ ] **Customization ownership model chosen** (Section 4 / Decision 2) — CS / customer / hybrid
- [ ] **Rollout cadence chosen** (Section 4 / Decision 3) — pilot-then-progressive / big-bang / new-customers-only
- [ ] **Existing-customer treatment chosen** (Section 4 / Decision 4) — proactive / reactive / sunset-date
- [ ] **Pricing/packaging decision** (Section 4 / Decision 5) — bundled / differentiator / premium / fee-waiver
- [ ] **CPack confirmed as pilot factory** — they're the natural choice (Phase 0 already used their data) but PM should confirm with their account owner
- [ ] **CS training budget approved** — Phase 7 workshop + cheat-sheet authoring (~1 engineer-week + 1 CS-lead-week)

---

## 10. Open questions worth a follow-up meeting

- Do we want CS engineers to be able to **see** the YAML config of every customer in a dashboard, or only via Git? (Visibility vs. workflow simplicity trade-off.)
- Should the `client.yaml` file be customer-visible in their own admin dashboard? Some buyers may want "show me what you configured for us" as a transparency feature; others will find it scary.
- Is there a security review needed for "customer's IT team commits to a Packiot Git repo"? (Only relevant if Decision 2 picks "customer owns it" or "hybrid".)
- Do we want to formally **deprecate** the old Node-RED-only path on a calendar date, or let it linger indefinitely? (See Decision 4; this is the harder version of that question.)

---

## Glossary

- **Node-RED** — A visual low-code tool for wiring data flows. Our Customer Success engineers use it to connect each customer's PLCs (factory equipment computers) to the platform. Drag-and-connect interface; supports embedding JavaScript inside "function" nodes. We've used it from day one because it's accessible to non-developers, but it has grown unwieldy.
- **edge-transformer** — The new Go service we're proposing. Sits next to Node-RED at each factory; does the standardized heavy lifting (PLC data normalization, time/shift math, configured integrations) so Node-RED only has to handle the customer-specific bits.
- **client.yaml** — A single configuration file per customer, in YAML format (human-readable, IDE-friendly, version-controllable). Replaces ~9,100 lines of configuration that today is embedded inside Node-RED as JavaScript.
- **Customization flow** — A Node-RED tab (visual workspace) used to implement a customer-specific behavior, like a state machine for a specific equipment line. After this migration, customization flows are the only thing CS still maintains in Node-RED — everything else moves to the YAML file or to the Go service.
- **Normalized payload** — A standard data structure (same shape for every customer, every PLC vendor) that edge-transformer produces from raw PLC data. Customer-specific code only ever sees this clean structure, never raw PLC bytes.
- **PLC** — Programmable Logic Controller. The industrial computer that controls factory equipment. Different vendors (Siemens, Allen-Bradley, B&R) speak different protocols (OPC-UA, SparkPlug B, Modbus); the differences are exactly what edge-transformer and `client.yaml` hide.
- **OPC-UA / SparkPlug B** — Two of the common industrial protocols for talking to PLCs. Most of our customers use one or the other; some use both. Customer-agnostic to product, but worth knowing the names exist.
- **Subflow** — A reusable mini-workspace inside Node-RED. Like a function in a regular programming language. After migration, customer state machines live in named subflows with documented contracts (defined inputs, defined outputs), not as sprawling tabs.
- **State machine** — A pattern for tracking what state a piece of equipment is in (idle, running, faulted, etc.). Customers build these on top of PLC inputs to express their definition of "uptime" vs "downtime". This is what Node-RED is best at — we're keeping it for this.
- **Schema version** — The version number stamped on every `client.yaml`. Lets us evolve the schema (add new fields, deprecate old ones) without breaking customers already in production.

---

*Questions or feedback: bring to the next product/engineering sync.*
