# PRODT-157 Operator: backlog and summary

Companion to the spec, [`PRODT-157-operator-app.md`](PRODT-157-operator-app.md), which holds the
`RN-` rules and `AC-` criteria the cards cite. This file has two parts, both copied verbatim from
what the team shared on 12 October 2026: the team summary, then the Jira backlog export. Jira is
the live source for card state; this file does not update itself.

---

# Operator Backlog Summary

Oct 12, 2026 · @Vinícius Silva Silva

The on-premise Operator's core flows work, but three defects block a factory rollout: creating a PO inside Change PO fails, the offline queue hides server refusals, and the Events tab neither limits itself to line stops nor shows more than 20 of them. Details, rules and acceptance criteria are in the Operator App Functional Specification and the backlog .md.

## Where we stand

11 of about 30 Operator features were tested between 7 and 12 October: 9 passed, 2 areas failed. QA logged 23 findings: 7 high, 9 medium, 5 low, 2 to assess.

- **Passed**: login and logout; enterprise switch (cloud staging and sandbox only); sidebar navigation; Change PO with no new PO (finish and pause); Change PO to an existing PO; Replace PO; Justify and Split (on staging, before writes were blocked there).
- **Failed**: Change PO when it creates a new PO; offline sync and its review tray.
- **Blocked**: every write test now runs in SANDBOX-CPACK, which has an orphan running PO on L5 and no event data. Until it is fixed, PO start, Justify, Split and manual downtime cannot be retested.

## Now

Six items for Sprint 7 (due 24 October), in this order. The first three are what an operator would hit in the first shift; the fourth unblocks testing; the fifth protects the numbers customers pay for; the sixth stops a tablet getting stuck with no PO.

| # | What | Why it matters | Done when | Component | Jira |
| --- | --- | --- | --- | --- | --- |
| 1 | Creating a new PO inside Change PO | Fails with a server error on every line tested, so operators cannot switch to a new order during a changeover | Create and pause, and create and finish, both succeed; a duplicate PO number gets a clear message; no input ever returns a server error | Operator, edge-api | PRODT-158 |
| 2 | Offline sync and error handling | Operators saw "Success" for actions the server refused, found them days later, and one failure blocked every later action on the tablet | Server refusals show at once with their message; only lost connections are queued; ordering is per line; the operator can open the pending list and keep or discard each action | Operator | PRODT-159, PRODT-160 |
| 3 | Events tab lists the right stops, all of them | Operators cannot reach pending stops beyond the first 20, and machine stops crowd the list | Only the line's own stops appear; every stop in the window is reachable; the badge matches the list | Read API, Operator | PRODT-161, PRODT-162 |
| 4 | Sandbox ready for testing | It is the only place write flows can be tested, and today PO start and all downtime features are blocked there | No orphan running PO; recent event data on at least one line | DevOps, data | PRODT-164 |
| 5 | Time rules in every time input | Wrong times silently corrupt OEE and PO totals | One picker, hours and minutes only; no future time; Split limited to the stop; back-dating at most 24 hours and never into another PO's runtime | Operator, edge-api | PRODT-165, PRODT-166 |
| 6 | Running PO always visible | The tablet showed no PO while the server had one running, so the operator could not start or change anything | The server's running PO always shows, with finish or pause offered; refusals show their own message | Operator, edge-api | PRODT-163 |

Most of this lands on the Operator front end. Items 1 and 2 span the backend too, so pairing the backend and frontend engineers on them is the fastest route.

One dependency to watch: item 3 leaves L3 with an empty Events tab, because C-PACK's L3 has produced no line-level stops since 3 October (B1). Fixing item 3 for C-PACK requires deciding where L3 line stops come from.

## Next

Improvements that make the Operator ready for daily use once Now is done.

| What | Outcome | Component | Jira |
| --- | --- | --- | --- |
| Justify field rules | Machine lists only the current line and its machines; category mandatory, subcategory too when the category has any | Operator | PRODT-171 |
| Replace PO, safe and traceable | The new PO is not set to running when the moved runtime is closed; each replacement is audited atomically with before and after totals | edge-api | PRODT-167, PRODT-168 |
| Replace PO, choose the runtimes | The operator picks which runtimes move; downtime and scrap follow their runtime | Operator, edge-api, database | PRODT-169 |
| Configurable Events window | Each enterprise sets how far back pending and history go (shift, day, last N hours), from when a stop started | CS Admin, read API | PRODT-170 |
| Sidebar and landing line | Natural sort; only permitted lines; open on the last line used | Operator, edge-api | PRODT-155, PRODT-172 |
| Alphanumeric PO numbers | PO numbers such as "ORD-7" work end to end | edge-api, database | PRODT-156 |
| Read-only mirror tenants | Write actions disabled with a note on CPACK-Staging | Operator | PRODT-173 |

## Later and parked

- **One line per PO (R14)**: not enforced today; parked until ADR-0023 decides whether a PO may run on several lines.
- **Audit trail for every write**: after Replace is fixed, extend the same standard to downtime edits, splits and status changes.
- **Source of L3 line stops (PRODT-176)**: deprioritised for now, but it gates the line-only Events tab on L3 (see Now, item 3).
- **Investigations**: the 8 Oct staging outage (PRODT-178), a PO at 250 times its order size (PRODT-177), staging vs production parity (PRODT-179).
- **Planned stops**: future manual downtime is blocked; scheduling planned stops stays in discovery until a customer asks.
- **Cosmetic fixes**: Change PO confirmation label, scrap display and payload types (PRODT-174); the ongoing-stop end time on the Events tab (PRODT-175).

## Decisions the team should know

- The product is the **on-premise Operator**, installed per factory for one customer. The enterprise switch exists only in cloud staging and sandbox.
- CPACK-Staging is a read-only mirror of production. **All write tests run in SANDBOX-CPACK.**
- The Events tab lists the **line's own stops only**, newest first; machine stops are not shown.
- **No time in the future** anywhere in the Operator, manual downtime included. Back-dated PO starts: at most 24 hours, never overlapping another PO.
- Only manual stops can have their times edited; on an automatic stop only the split time can be chosen. Manual stops cannot be deleted for now.
- Replace PO: the old PO becomes available with no runtime left, paused with at least one; downtime follows its runtime.

## Jira housekeeping

Done on 12 October. Epic **PRODT-157** holds the whole backlog, every item assigned to Emmanuel Podesta with Vinícius as reporter. Rules and acceptance criteria live in the spec in packiot-stack-alpha, `docs/specs/PRODT-157-operator-app.md`; cards cite their IDs.

- Created Epic PRODT-157 and items PRODT-158 to PRODT-179; moved PRODT-38, PRODT-155 and PRODT-156 under it.
- Created the `operator` component in Jira and Compass.
- PRODT-17 and PRODT-52 (cloud Operator) need a manual close with resolution Won't Do; a comment on each asks for it. Items in archived projects (PRIMARY-38, PCKT-22, SCRUM-39) were left as they are.
- Still open: a Sprint 7 Fix Version, Original Estimates and Story Points at refinement, Team on the edge-api-only items, and PRODT-38's owner confirming what remains beyond PRODT-158.

---

# On-premise Operator App: Jira backlog (PRODT-157)

Snapshot of every work item under Epic [PRODT-157](https://packiotdev.atlassian.net/browse/PRODT-157), exported from Jira on 12 October 2026. Jira is the live source; this file does not update itself.

**How to read it**

- Acceptance criteria (`AC-xx`) and business rules (`RN-xx`) are cited by ID only. Their full text lives in the spec, `docs/specs/PRODT-157-operator-app.md` in packiot-stack-alpha (status: in-review). Share the spec alongside this file.
- `BUG-AC-xx` criteria belong to the card itself because the spec does not cover that bug.
- Spikes are Jira Tasks labelled `discovery`.
- Every item is assigned to Emmanuel Podesta, except PRODT-38 (pre-existing, William Rodrigues). Original Estimates and Story Points are set at refinement; there is no Fix Version yet.

## Overview

26 items: 1 Epic, 11 Stories, 9 Bugs, 1 Task and 4 Spikes.

| Key | Type | Summary | Priority | Status | Due | Plan |
| --- | --- | --- | --- | --- | --- | --- |
| [PRODT-158](https://packiotdev.atlassian.net/browse/PRODT-158) | Bug | Change PO: creating a new PO in the flow returns 500 | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-159](https://packiotdev.atlassian.net/browse/PRODT-159) | Bug | Offline sync queues server refusals and hides their messages | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-160](https://packiotdev.atlassian.net/browse/PRODT-160) | Story | Pending actions list: keep, discard and safe time-correction | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-161](https://packiotdev.atlassian.net/browse/PRODT-161) | Bug | Events tab shows only the first 20 pending stops while the badge counts all | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-162](https://packiotdev.atlassian.net/browse/PRODT-162) | Bug | Events tab lists machine stops on the line | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-163](https://packiotdev.atlassian.net/browse/PRODT-163) | Bug | Operator shows no PO while the server has one running; nothing can be started | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-164](https://packiotdev.atlassian.net/browse/PRODT-164) | Task | Prepare SANDBOX-CPACK for write-flow testing (orphan POs, event data) | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-165](https://packiotdev.atlassian.net/browse/PRODT-165) | Story | One time picker with the Operator's time rules | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-166](https://packiotdev.atlassian.net/browse/PRODT-166) | Bug | PO start can be back-dated with no limit and into another PO's runtime | High | To Do | 2026-10-24 | Now (Sprint 7) |
| [PRODT-167](https://packiotdev.atlassian.net/browse/PRODT-167) | Bug | Replace sets the new PO to Running when the moved runtime is closed | Medium | To Do |  | Next |
| [PRODT-168](https://packiotdev.atlassian.net/browse/PRODT-168) | Story | Audit trail for Replace PO | Medium | To Do |  | Next |
| [PRODT-169](https://packiotdev.atlassian.net/browse/PRODT-169) | Story | Replace PO: choose which runtimes move | Medium | To Do |  | Next |
| [PRODT-170](https://packiotdev.atlassian.net/browse/PRODT-170) | Story | Configurable pending and history windows per enterprise | Medium | To Do |  | Next |
| [PRODT-171](https://packiotdev.atlassian.net/browse/PRODT-171) | Story | Justify, Split and manual stops follow the line and reason rules | Medium | To Do |  | Next |
| [PRODT-172](https://packiotdev.atlassian.net/browse/PRODT-172) | Story | Line permissions and landing line on login | Medium | To Do |  | Next |
| [PRODT-155](https://packiotdev.atlassian.net/browse/PRODT-155) | Story | Operator sidebar: natural sort order of areas and lines | Medium | To Do |  | Next |
| [PRODT-156](https://packiotdev.atlassian.net/browse/PRODT-156) | Story | Alphanumeric PO numbers work end to end in Pack Stack Alpha | Medium | To Do |  | Next |
| [PRODT-176](https://packiotdev.atlassian.net/browse/PRODT-176) | Spike (Task) | Spike: source of C-PACK L3 line-level stops | Medium | To Do |  | Next |
| [PRODT-173](https://packiotdev.atlassian.net/browse/PRODT-173) | Story | Disable write actions on read-only mirror tenants | Low | To Do |  | Later |
| [PRODT-174](https://packiotdev.atlassian.net/browse/PRODT-174) | Bug | Change PO confirmation: scrap decreases, wrong label and payload types | Low | To Do |  | Later |
| [PRODT-175](https://packiotdev.atlassian.net/browse/PRODT-175) | Bug | Events tab: ongoing stops render a dangling "at [-]" end time | Low | To Do |  | Later |
| [PRODT-177](https://packiotdev.atlassian.net/browse/PRODT-177) | Spike (Task) | Spike: PO 891330 on L6 shows about 250 times its order size | Low | To Do |  | Later |
| [PRODT-178](https://packiotdev.atlassian.net/browse/PRODT-178) | Spike (Task) | Spike: cause of the CPACK-Staging 502 outage on 8 Oct 2026 | Low | To Do |  | Later |
| [PRODT-179](https://packiotdev.atlassian.net/browse/PRODT-179) | Spike (Task) | Spike: CPACK-Staging stops differ from production (reasons and timestamps) | Low | To Do |  | Later |
| [PRODT-38](https://packiotdev.atlassian.net/browse/PRODT-38) | Story | Create Change Production Orders Feature | Medium | In Progress |  | Existing |

## Epic

### [PRODT-157](https://packiotdev.atlassian.net/browse/PRODT-157): On-premise Operator App: production readiness

| Field | Value |
| --- | --- |
| Type | Epic |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | CS Admin, edge-api, operator, packiot-stack-alpha |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** The Operator ships as an on-premise app installed at each factory for one customer (the cloud Operator is stopped). QA from 7 to 12 Oct 2026 showed the core flows work, but three defects block a factory rollout: creating a PO inside Change PO returns 500; the offline queue treats server refusals as lost connections and one failure blocks every later action; the Events tab mixes machine stops into the line list and shows only 20 pending stops.

**Current:** Login, logout, top bar, line switching, Replace PO and the basic Justify flow work. PO, downtime and offline-sync rules are partly unenforced or untested (see the spec's QA evidence).

**Expected:** The Operator meets every acceptance criterion in the spec, so a factory can run POs and classify downtime with correct OEE inputs, online and offline.

**Must not happen:** Wrong PO times, downtime attributed to the wrong PO or line, or pending stops hidden from the operator. These produce plausible but wrong OEE, so this Epic is tier large (industrial data correctness).

#### Use Cases

* As an operator, I want to start, change, pause, finish and replace production orders on my line, so that production is counted against the right order.
* As an operator, I want to justify and split the stops of my line, so that downtime reports are accurate.
* As an operator, I want my actions to sync reliably when the network drops, and to see at once when the server refuses one, so that I never act on a false "Success".
* As a supervisor, I want every PO replacement audited, so that a wrong one can be found and reversed.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`. Criteria are cited, never restated. The Epic is done when every child item is Done and these groups pass UAT:

- [ ] **App shell**: AC-01 to AC-05, AC-39
- [ ] **Production orders**: AC-06 to AC-16
- [ ] **Events tab**: AC-17 to AC-21, AC-37
- [ ] **Downtime**: AC-22 to AC-28, AC-38
- [ ] **Shared UI**: AC-29, AC-30
- [ ] **Offline sync**: AC-31 to AC-36
- [ ] **Spec approved**: OQ-01 and OQ-02 closed, front matter moved from in-review to approved

#### Requirements

Business rules RN-01 to RN-25 and NFR-01 to NFR-03 live in the spec.

#### User Acceptance Test

- [ ] **UAT-01 Shift run**: Precondition: SANDBOX-CPACK prepared (PRODT-164). Action: one full shift on a line: start a PO, Change PO creating a new PO, Replace, justify and split stops. Expected: every step succeeds and PO and downtime totals match the shift.
- [ ] **UAT-02 Offline**: Precondition: tablet offline for 30 minutes. Action: justify two stops and pause the PO, then reconnect. Expected: all three sync; "Success" only after server confirmation.
- [ ] **UAT-03 Failure path**: Precondition: a PO number already in use. Action: create it in Change PO. Expected: a 400 message naming the conflict; nothing queued; later actions on other lines are not blocked.

#### Impact

**Features:** production orders (Change PO, Replace, start), Events tab, Justify and Split, offline sync, sidebar and permissions.

**Additional:** APIs (edge-api), database (serving functions, user_logs), frontend (operator), CS Admin configuration, reports (PO and downtime totals), documentation, support and training for factory rollout.

#### Dependencies

* PRODT-164: SANDBOX-CPACK ready for write-flow testing (CPACK-Staging is a read-only mirror).
* ADR-0023 (PO on several lines) for OQ-01; ADR-0062 migrations for alphanumeric PO numbers (PRODT-156).
* PRODT-176 (L3 line-level stops) for AC-37 and OQ-02.

#### Out of scope

* The stable-generation Operator (operator4) and the cloud Operator (PRODT-17, PRODT-52 superseded).
* Desktop app changes beyond Justify and Split parity (AC-38).
* PO runs on several lines (ADR-0023); planned future stops (discovery).

#### Risks

* Industrial data correctness: Replace and back-dating change PO totals that feed customer reports; validate against production numbers before release.
* Line-only Events (RN-16) leaves C-PACK L3 with an empty list until AC-37 is met.
* A configurable window can leave stops permanently unclassified; a grace period is proposed.
* One assignee for 24 child items: deliver the Now items first.

#### Delivery plan

* **Now (Sprint 7, due 24 Oct 2026)**: PRODT-158, PRODT-159, PRODT-160, PRODT-161, PRODT-162, PRODT-163, PRODT-164, PRODT-165, PRODT-166.
* **Next**: PRODT-167, PRODT-168, PRODT-169, PRODT-170, PRODT-171, PRODT-172, PRODT-155, PRODT-156, PRODT-176.
* **Later**: PRODT-173, PRODT-174, PRODT-175, PRODT-177, PRODT-178, PRODT-179. Existing: PRODT-38.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md` (packiot-stack-alpha)
* Functional spec and QA notes (Claude doc): Operator App Functional Specification
* Team summary (Claude doc): Operator Backlog Summary
* ADRs: ADR-0023, ADR-0054, ADR-0055, ADR-0062

## Now: Sprint 7 (13 to 24 October 2026)

### [PRODT-158](https://packiotdev.atlassian.net/browse/PRODT-158): Change PO: creating a new PO in the flow returns 500

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

Change Production Order fails with HTTP 500 whenever the operator creates a new PO in the flow (Create new PO plus pause, and plus finish). The Operator sends the typed PO number in `idProductionOrder` and never sends `shouldCreatePo`, so the server tries to start a PO that does not exist and returns an untranslated database error.

#### Expected behaviour

The new PO is created and starts at the chosen time; the current PO is paused or finished; the response is 201. A duplicate PO number gets a 400 with a clear message.

#### Steps to reproduce

1. Open the Operator on a line with a running PO.
2. Change Production Order, step 2: Enable other options, create a new PO (any number, for example 12457845), choose Pause or Finish.
3. Confirm: the response is 500 {"statusCode":500,"message":"Internal server error"}.

#### Environment

`staging` (CPACK-Staging, enterprise 3, lines L4, L5, L6, 8 Oct 2026). Components: operator, edge-api.

#### Causing deploy

Not identified. Seen on the deployed staging build of 8 Oct 2026; Operator code read at 24 Sep 2026, edge-api at 27 Aug 2026.

#### Severity and impact

Blocks every changeover to a new order from the shop floor. No data corrupted (the request is refused in one transaction). Workaround: create the PO first, then change to it as an existing PO.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-06**
- [ ] **AC-07**
- [ ] **AC-08**
- [ ] **AC-09**
- [ ] Regression test covering this defect exists and fails against the unfixed code.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification
* Requests: POST /api/production-orders/setup?idEnterprise=3 on 8 Oct 2026 at 12:30, 12:34 and 12:38 local (L6, L5, L4).

### [PRODT-159](https://packiotdev.atlassian.net/browse/PRODT-159): Offline sync queues server refusals and hides their messages

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

When the tablet is online and the server refuses an action (500, 400, 403, 409), the Operator stores it in the offline queue, shows "Success! Wait for data synchronization", retries it in the background and later parks it in the review tray. Server messages are replaced by "Oops! An error occurred.". One failed action blocks every later action on the tablet.

#### Expected behaviour

Server refusals while online are shown at once with the server's message and never queued; only lost connections are queued; ordering is per line, so a failure on one line never blocks another.

#### Steps to reproduce

1. Online, run Change PO with a new PO (fails with 500, see the Change PO bug).
2. Observe the Success toast and the sync badge.
3. Run any other action on the same or another line: it waits behind the failed one.
4. Open the review tray days later: the refused actions are listed as "Could not be applied".

#### Environment

`staging` (CPACK-Staging and SANDBOX-CPACK), 8 and 12 Oct 2026. Component: operator (Services/durableWrite.js, writeQueue.js).

#### Causing deploy

Not identified.

#### Severity and impact

Operators believe actions were saved when they were refused; a create-and-finish test on 8 Oct at 12:36 was blocked behind two failures and later refused. Risk of wrong PO history if parked actions are applied days later.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-30**
- [ ] **AC-31**
- [ ] **AC-32**
- [ ] **AC-33**
- [ ] Regression test covering this defect exists and fails against the unfixed code.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification
* Review tray screenshot of 12 Oct 2026 (four parked actions from 8 Oct).

### [PRODT-160](https://packiotdev.atlassian.net/browse/PRODT-160): Pending actions list: keep, discard and safe time-correction

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Operators need to see and control actions waiting to sync; today the badge covers the plus button and parked actions can be replayed days later with no preview.

**Current:** A badge at the bottom right overlaps the plus button; a review tray offers "Apply as time-correction" and "Discard" with no preview of what will change and no age limit.

**Expected:** A badge below the top bar shows waiting and failed counts and disappears when everything has synced; tapping it opens the pending list where each action can be kept or discarded; time-corrections show their effect before confirming; old actions need a supervisor.

**Must not happen:** A parked action rewriting PO history without the operator seeing what moves.

#### Use Cases

* As an operator, I want to see which actions have not synced yet, so that I know what the system has really recorded.
* As an operator, I want to discard an action the server refused, so that the screen matches the server again.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-34**
- [ ] **AC-35**
- [ ] **AC-36**

#### Requirements

Business rules live in the spec: RN-24.

#### User Acceptance Test

- [ ] **UAT-01 Keep and discard**: Precondition: tablet offline, two actions taken. Action: reconnect with one action failing. Expected: the list shows one synced, one failed; discard removes it and the screen shows the server state.
- [ ] **UAT-02 Time-correction preview**: Precondition: a parked PO change. Action: Apply as time-correction. Expected: PO, time span and production that move are shown before confirming.
- [ ] **UAT-03 Failure path**: Precondition: a parked action older than the end of its shift. Action: apply it as an operator. Expected: refused, supervisor permission required.

#### Impact

Components: operator. Additional: frontend, documentation, support and training.

#### Dependencies

* PRODT-159 Offline sync bug (server refusals must stop entering the queue first).

#### Out of scope

* Changing which responses are queued (covered by PRODT-159).

#### Risks

* Supervisor permission needs a role model in the Operator; confirm it exists before Ready.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-161](https://packiotdev.atlassian.net/browse/PRODT-161): Events tab shows only the first 20 pending stops while the badge counts all

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator, packiot-stack-alpha |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

The Events tab badge counts every pending stop, but the Operator keeps only the first 20 rows (and 50 in the history). On L5 the badge showed 39; 19 stops, the oldest, cannot be reached or justified from the Operator.

#### Expected behaviour

Every pending stop in the window is reachable by scrolling or paging, and the badge counts exactly the stops the list can show.

#### Steps to reproduce

1. Open the Events tab on a line with more than 20 pending stops (L5 on 12 Oct 2026).
2. Scroll to the end of the pending list.
3. Only 20 rows are reachable while the badge shows a higher number.

#### Environment

`staging` (CPACK-Staging, L5, 12 Oct 2026). Components: operator (Services/endpoints.js getPendingEvents), packiot-stack-alpha (serving.pending_downtime).

#### Causing deploy

Not identified.

#### Severity and impact

Oldest stops are never classified; downtime reasons are missing from reports for those minutes.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-18**
- [ ] **AC-19**
- [ ] Regression test covering this defect exists and fails against the unfixed code.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-162](https://packiotdev.atlassian.net/browse/PRODT-162): Events tab lists machine stops on the line

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator, packiot-stack-alpha |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

The Events tab lists stops recorded on the line's machines (for example BREYER, RMH and POLYTYPE under L3) as if they were line stops. Simultaneous stops on two machines look like duplicates, and machine stops with overlapping times look like a violation of the no-overlap rule.

#### Expected behaviour

Only stops recorded on the line itself appear in the pending and history lists, whether or not a PO was running.

#### Steps to reproduce

1. Open the Events tab on L3 or L5 in CPACK-Staging.
2. Compare the rows with the equipment of each event in GET /v1/pending-downtime.
3. Rows from the line's machines appear in the line's list.

#### Environment

`staging` (CPACK-Staging, L3 on 7 Oct 2026, L5 on 12 Oct 2026). Components: packiot-stack-alpha (serving.pending_downtime, serving.events_timeline), operator.

#### Causing deploy

Not identified.

#### Severity and impact

Operators are asked to justify machine stops customers do not track; the list is crowded and misleading. Note: on C-PACK L3 the line itself has had no stops since 3 Oct 2026, so this fix empties L3's tab until the L3 line-stops investigation is resolved.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-17**
- [ ] Regression test covering this defect exists and fails against the unfixed code.
- [ ] The existing justification of line stops keeps working on L4, L5 and L6.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification
* Payload of 7 Oct 2026: equipment 58, 59 and 62 under L3 (equipment 48).

### [PRODT-163](https://packiotdev.atlassian.net/browse/PRODT-163): Operator shows no PO while the server has one running; nothing can be started

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

On SANDBOX-CPACK L5 the Operator shows "No Production Order selected yet", but create and start returns 400 "Cannot start an order without finish the current one!". The server sees a running PO the Operator does not list, so the operator can neither finish it nor start a new one.

#### Expected behaviour

Whenever the server reports a running PO on a line, the Operator shows it with the option to finish or pause it, and server messages reach the operator.

#### Steps to reproduce

1. Open SANDBOX-CPACK, line L5 (equipment 2000047).
2. Create a PO (808080, quantity 400100) and confirm.
3. The request fails with 400 and the toast says "Oops! An error occurred.".

#### Environment

`staging` (SANDBOX-CPACK, enterprise 2000003, 12 Oct 2026). Components: operator, edge-api.

#### Causing deploy

Not identified. Likely a cloned PO with status Running and no open runtime; the same state is tracked as a known invariant violation in production, so it can happen there too.

#### Severity and impact

Deadlock for the line: no PO can be started. Blocks every PO test in the sandbox.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-12**
- [ ] **AC-30**
- [ ] Regression test covering this defect exists and fails against the unfixed code.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification
* Request: POST /api/production-orders/create-and-start?idEnterprise=2000003, 12 Oct 2026 18:00.

### [PRODT-164](https://packiotdev.atlassian.net/browse/PRODT-164): Prepare SANDBOX-CPACK for write-flow testing (orphan POs, event data)

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Task |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | packiot-stack-alpha |
| Team | DevOps & SRE |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Description

SANDBOX-CPACK (enterprise 2000003) is the only tenant where write flows can be tested, since CPACK-Staging now refuses writes. Today L5 has an orphan running PO (see PRODT-163) and the Events tab is empty because the sandbox has no recent stops. Clean the orphan POs and give at least one line recent event data, so PO start, Justify, Split and manual downtime can be retested.

#### Acceptance Criteria

- [ ] **AC-01**: Given SANDBOX-CPACK, when a query lists POs with status Running, then every one has an open runtime.
- [ ] **AC-02**: Given L5 in the sandbox, when the Events tab opens, then stops from the last 24 hours are listed.
- [ ] **AC-03**: A reset of the sandbox to CPACK-Staging does not reintroduce orphan running POs.
- [ ] **AC-04**: CPACK-Staging (enterprise 3) is untouched by this work.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification
* Queries to confirm the state are in the Operator App Functional Specification doc, section Shared UI and data rules.

### [PRODT-165](https://packiotdev.atlassian.net/browse/PRODT-165): One time picker with the Operator's time rules

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Wrong times silently corrupt OEE and PO totals. Today three different pickers allow future times, show seconds and do not respect a stop's limits.

**Current:** Split opens an empty native picker that suggests the current time, even outside the stop; Create PO shows seconds; the desktop Downtimes page behaves the same.

**Expected:** One picker for every time input, hours and minutes only, no future time; Split limited to the stop and defaulting to one minute after its start.

**Must not happen:** Any time input accepting a moment after now; a split time outside the stop.

#### Use Cases

* As an operator, I want the picker to offer only valid times, so that I cannot record a stop or PO change at an impossible moment.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-11**
- [ ] **AC-24**
- [ ] **AC-27**
- [ ] **AC-29**

#### Requirements

Business rules live in the spec: RN-10, RN-20, RN-23.

#### User Acceptance Test

- [ ] **UAT-01 Split limits**: Precondition: stop 05:40 to 05:46. Action: open Split. Expected: default 05:41; only 05:41 to 05:45 selectable.
- [ ] **UAT-02 No future**: Precondition: any time input. Action: try a time after now. Expected: not offered; a crafted request is refused by the server.
- [ ] **UAT-03 Failure path**: Precondition: ongoing stop. Action: pick a split time. Expected: nothing after now is offered.

#### Impact

Components: operator, edge-api (server validation). Additional: frontend, desktop parity (front4).

#### Dependencies

* None.

#### Out of scope

* Back-dating limits for PO starts (separate bug).

#### Risks

* Desktop parity needs the same change in front4 (AC-38).

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-166](https://packiotdev.atlassian.net/browse/PRODT-166): PO start can be back-dated with no limit and into another PO's runtime

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | High |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator |
| Team | Front-end |
| Due date | 2026-10-24 |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

A new PO start can be back-dated without a limit: a Change PO on L4 on 8 Oct 2026 started the new PO 27 hours in the past, taking over 28,172 units while the old PO was declared at 40,100, against about 30,386 counted on the line.

#### Expected behaviour

A PO start can be back-dated by at most 24 hours and never into another PO's runtime on the same line; no time after now is accepted.

#### Steps to reproduce

1. Run Change PO to an existing PO on a line with a running PO.
2. Set the start time more than 24 hours back.
3. Confirm: the request succeeds today.

#### Environment

`staging` (CPACK-Staging, L4, 8 Oct 2026). Components: edge-api, operator.

#### Causing deploy

Not identified.

#### Severity and impact

Production can be counted twice across POs; OEE per PO becomes wrong without any error.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-10**
- [ ] **AC-11**
- [ ] Regression test covering this defect exists and fails against the unfixed code.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification
* Request: POST /api/production-orders/setup?idEnterprise=3 with timestamp 2026-10-07T08:42:00-03:00 sent on 8 Oct.

## Next

### [PRODT-167](https://packiotdev.atlassian.net/browse/PRODT-167): Replace sets the new PO to Running when the moved runtime is closed

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api |
| Team | Not set |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

Found by code reading, not yet reproduced: Replace always sets the new PO to Running, even when the runtime it moves is already closed.

#### Expected behaviour

The new PO becomes Running only when the moved runtime is open; otherwise its status follows its runtimes.

#### Steps to reproduce

1. Take a PO with a closed runtime.
2. Call POST /api/production-orders/replace with that runtime as runtimeToReplace.
3. Check the new PO's status: Running.

#### Environment

edge-api code at 27 Aug 2026 (repositories/database/production-order-database.ts, replace). Component: edge-api.

#### Causing deploy

Not identified.

#### Severity and impact

A finished period could appear as a running PO; possible conflict with the one-running-PO-per-line rule.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-13**
- [ ] Regression test covering this defect exists and fails against the unfixed code.
- [ ] Replacing the open runtime keeps working as tested on 8 Oct 2026.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-168](https://packiotdev.atlassian.net/browse/PRODT-168): Audit trail for Replace PO

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api |
| Team | Not set |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Replacing a PO moves production between orders; without a reliable record nobody can detect or reverse a wrong replacement.

**Current:** The audit row is written after the response, outside the transaction; failures are swallowed; the payload is the request body only; the user comes from the client-supplied x-user header.

**Expected:** Each Replace writes one audit entry in the same transaction, with the verified user, old and new PO, runtimes moved and both POs' totals before and after.

**Must not happen:** A replacement without an audit entry, or an audit entry for a replacement that did not happen.

#### Use Cases

* As a supervisor, I want to see who replaced which PO and what moved, so that I can reverse a wrong replacement.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-14**

#### Requirements

Business rules live in the spec: RN-15.

#### User Acceptance Test

- [ ] **UAT-01 Audit entry**: Precondition: running PO. Action: Replace. Expected: one user_logs entry with before and after totals.
- [ ] **UAT-02 Failure path**: Precondition: force a database error during Replace. Action: Replace. Expected: no change and no audit entry.

#### Impact

Components: edge-api. Additional: database, auditability.

#### Dependencies

* None.

#### Out of scope

* The same standard for every other write (follows once Replace is done).

#### Risks

* The shared logger middleware serves every write; changing it affects all endpoints.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-169](https://packiotdev.atlassian.net/browse/PRODT-169): Replace PO: choose which runtimes move

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator, packiot-stack-alpha |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Operators replace a wrong or placeholder PO, but sometimes only part of the old PO's production belongs to the new one.

**Current:** Replace moves only the open runtime. PO downtime is counted over the PO's whole first-start-to-last-end window, so a PO keeping runtimes on both sides of a moved one would also count the moved runtime's downtime.

**Expected:** The operator chooses which runtimes move, the open one preselected; stops, scrap and manual events move with their runtime; both POs are recalculated from their own runtime windows.

**Must not happen:** Production or downtime counted in both POs, or lost from both.

#### Use Cases

* As an operator, I want to move only the wrong runtimes to the right PO, so that the correct production stays with each order.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-15**

#### Requirements

Business rules live in the spec: RN-13, RN-14.

#### User Acceptance Test

- [ ] **UAT-01 Partial replace**: Precondition: PO with runtimes R1, R2, R3. Action: replace R2. Expected: R2 and its stops on the new PO; totals equal the sum of each PO's runtimes.
- [ ] **UAT-02 Failure path**: Precondition: target PO running on another line. Action: replace. Expected: refused with a message.

#### Impact

Components: operator, edge-api, packiot-stack-alpha (PO detail views). Additional: database, reports.

#### Dependencies

* PRODT-167 (Replace closed-runtime bug).
* Audit trail for Replace PO.

#### Out of scope

* PO runs on several lines (ADR-0023).

#### Risks

* Industrial data correctness: PO totals feed customer reports; validate against production numbers before release.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-170](https://packiotdev.atlassian.net/browse/PRODT-170): Configurable pending and history windows per enterprise

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | CS Admin, operator, packiot-stack-alpha |
| Team | Not set |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Customers want operators to see only the stops that matter to the current shift or day; today the windows are fixed in the database (4 days pending; history started in 7 days and ended in 24 hours).

**Current:** Fixed windows in serving.pending_downtime and serving.events_timeline; not configurable.

**Expected:** Each enterprise sets a pending window and a history window in CS Admin: current shift, current production day, or the last N hours, applied to a stop's start time, never longer than 7 days.

**Must not happen:** Ongoing stops hidden; windows longer than 7 days; the badge counting a different set than the list.

#### Use Cases

* As a CS engineer, I want to set how far back operators see stops, so that each customer sees what matches their shift routine.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-20**
- [ ] **AC-21**

#### Requirements

Business rules live in the spec: RN-17, RN-18.

#### User Acceptance Test

- [ ] **UAT-01 Shift window**: Precondition: window = current shift. Action: open the Events tab. Expected: stops started this shift plus any ongoing stop.
- [ ] **UAT-02 Failure path**: Precondition: CS Admin. Action: set 10 days. Expected: refused.

#### Impact

Components: CS Admin, packiot-stack-alpha (serving functions), operator. Additional: configuration, documentation.

#### Dependencies

* PRODT-162 and PRODT-161 (Events tab bugs) fixed first.

#### Out of scope

* Per-line windows; a supervisor view of stops that left the window (proposed separately).

#### Risks

* Hidden stops become permanently unclassified; consider a grace period after shift change.
* Keep a literal time bound in the queries (NFR-01).

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-171](https://packiotdev.atlassian.net/browse/PRODT-171): Justify, Split and manual stops follow the line and reason rules

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Justifications drive downtime reports; wrong machines or missing subcategories make them unusable.

**Current:** Rules not verified: whether Justify lists machines from other lines, whether a subcategory is enforced, and whether manual stops can overlap other stops (the create endpoint has no overlap check in the code read).

**Expected:** Justify lists only the current line and its machines; a split must cover the stop exactly; category mandatory, subcategory mandatory when it exists; manual stops never overlap; only manual stops have editable times.

**Must not happen:** A justification with a machine from another line; a manual stop overlapping another stop.

#### Use Cases

* As an operator, I want to pick only my line's machines and complete reasons, so that the downtime report is accurate.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-22**
- [ ] **AC-23**
- [ ] **AC-25**
- [ ] **AC-26**
- [ ] **AC-28**
- [ ] **AC-38**

#### Requirements

Business rules live in the spec: RN-19, RN-20, RN-21, RN-22.

#### User Acceptance Test

- [ ] **UAT-01 Machine list**: Precondition: pending stop on L5. Action: open Justify. Expected: Geral - Linha and L5 machines only.
- [ ] **UAT-02 Failure path**: Precondition: automatic stop 10:00 to 10:20. Action: create a manual stop 10:10 to 10:30. Expected: refused with a message.

#### Impact

Components: operator, edge-api. Additional: desktop parity (front4).

#### Dependencies

* PRODT-164 (sandbox ready for write testing).
* PRODT-165 (time picker: Split default and bounds, AC-24).

#### Out of scope

* Deleting manual stops (decided: not offered).

#### Risks

* Desktop parity needed (AC-38).

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-172](https://packiotdev.atlassian.net/browse/PRODT-172): Line permissions and landing line on login

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Operators should land on their line and see only what they may act on.

**Current:** Not tested with a restricted user; the landing rule is not implemented.

**Expected:** The sidebar shows only permitted lines, the server refuses others, and login opens the last line used, else the first permitted line, else an empty state.

**Must not happen:** A user reading or writing data of a line they are not permitted on.

#### Use Cases

* As an operator, I want to land on the line I work on, so that I can start the shift without searching.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-02**
- [ ] **AC-03**
- [ ] **AC-04**

#### Requirements

Business rules live in the spec: RN-02, RN-03.

#### User Acceptance Test

- [ ] **UAT-01 Landing**: Precondition: user last on L6. Action: log in on another tablet. Expected: L6 opens.
- [ ] **UAT-02 Failure path**: Precondition: user with no permitted line. Action: log in. Expected: the empty-state message, no error.

#### Impact

Components: operator, edge-api. Additional: security.

#### Dependencies

* A restricted test user in the sandbox.

#### Out of scope

* Permission administration screens.

#### Risks

* Server-side enforcement must not rely on the menu.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-155](https://packiotdev.atlassian.net/browse/PRODT-155): Operator sidebar: natural sort order of areas and lines

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Operators scan the sidebar to find their line; an ID-based order puts L5 before L3 and CELULA areas after LINHAS.

**Current:** Areas and equipment follow internal IDs: LINHAS, CELULA1, CELULA2; L5, L3, L4, L6, L8, L10.

**Expected:** Natural sort: areas first, then equipment within each area, numbers compared as numbers.

**Must not happen:** Plain alphabetical order putting L10 before L3.

#### Use Cases

* As an operator, I want lines in natural order, so that I find mine at a glance.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-01**
- [ ] **AC-39**

#### Requirements

Business rules live in the spec: RN-01.

#### User Acceptance Test

- [ ] **UAT-01 Order**: Precondition: C-PACK enterprise. Action: open the sidebar. Expected: CELULA1, CELULA2, CELULA9, LINHAS, SLEEVE; L3, L4, L5, L6, L8, L10.
- [ ] **UAT-02 Failure path**: Precondition: a line named L10. Action: open the sidebar. Expected: L10 after L8, not after L1.

#### Impact

Components: operator.

#### Dependencies

* None.

#### Out of scope

* Permission filtering (PRODT-172).

#### Risks

* None significant.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-156](https://packiotdev.atlassian.net/browse/PRODT-156): Alphanumeric PO numbers work end to end in Pack Stack Alpha

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | edge-api, operator, packiot-stack-alpha |
| Team | Not set |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** Customers use alphanumeric order numbers; the edge-api DTOs and some columns type the PO number as an integer.

**Current:** setup and create-and-start type idOrder as a number; ADR-0062 migrations add a text column.

**Expected:** PO numbers such as "ORD-7" work in every PO action and display unchanged.

**Must not happen:** A PO number truncated, rejected or converted.

#### Use Cases

* As an operator, I want to type the customer's order number as it is, so that production matches the planning system.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-16**
- [ ] **AC-08**

#### Requirements

Business rules live in the spec: RN-09.

#### User Acceptance Test

- [ ] **UAT-01 Alphanumeric**: Action: create, start, change and replace PO "ORD-7". Expected: all succeed and display ORD-7.
- [ ] **UAT-02 Failure path**: Action: create "ORD-7" twice. Expected: second is refused with a clear message.

#### Impact

Components: edge-api, packiot-stack-alpha, operator. Additional: database, reports, integrations.

#### Dependencies

* ADR-0062 migrations.
* PRODT-158 (Change PO create path) shares AC-08.

#### Out of scope

* Renumbering existing POs.

#### Risks

* Reports and BI joins on the PO number.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-176](https://packiotdev.atlassian.net/browse/PRODT-176): Spike: source of C-PACK L3 line-level stops

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Spike (Task) |
| Status | To Do |
| Priority | Medium |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | packiot-stack-alpha |
| Team | Not set |
| Due date | Not set |
| Labels | discovery |
| Enterprise | C-Pack |

#### Question to answer

What should produce C-PACK L3 line-level stops now that the legacy mirror no longer does? L3 (equipment 48) has had no line stops since 3 Oct 2026, so the line-only Events tab will be empty for L3.

#### Time-box

1 day.

#### Decision this unblocks

PRODT-162 (Events tab line-only, AC-17) and AC-37 in the spec; open question OQ-02.

#### Completion criteria

- [ ] The question has a documented answer, in an ADR, the spec or a comment on this card.
- [ ] The blocked card or decision has been updated with the answer.

#### Expected output

A recommendation on the card (for example enabling downtime_from_lead_machine for C-PACK lines, or restoring the mirror path), then a Story if a change is needed.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

## Later

### [PRODT-173](https://packiotdev.atlassian.net/browse/PRODT-173): Disable write actions on read-only mirror tenants

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | To Do |
| Priority | Low |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Description

**Why now:** On CPACK-Staging every write is refused, but the Operator still offers write actions, so testers fill a form and then get a 403.

**Current:** Justify, Split, Change PO and Replace are enabled on enterprise 3; the server answers 403 MIRROR_TENANT_WRITE_BLOCKED.

**Expected:** On a mirror tenant write actions are disabled with a note to use the sandbox.

**Must not happen:** Any write request sent from a mirror tenant.

#### Use Cases

* As a tester, I want to know before filling a form that this tenant is read-only, so that I test in the sandbox instead.

#### Acceptance Criteria

Spec: `docs/specs/PRODT-157-operator-app.md`

- [ ] **AC-05**

#### Requirements

Business rules live in the spec: RN-05.

#### User Acceptance Test

- [ ] **UAT-01 Disabled actions**: Precondition: CPACK-Staging. Action: open the Events tab. Expected: Justify and Split disabled with the note.
- [ ] **UAT-02 Failure path**: Precondition: CPACK-Staging. Action: craft a write request. Expected: 403 shown with its message, not queued.

#### Impact

Components: operator. Additional: cloud staging only (the on-premise Operator has no mirror tenant).

#### Dependencies

* None.

#### Out of scope

* Production tenants.

#### Risks

* None significant.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-174](https://packiotdev.atlassian.net/browse/PRODT-174): Change PO confirmation: scrap decreases, wrong label and payload types

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | Low |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

In Change Production Order: (1) scrap went down between steps of the same flow (1,337 on step 1, 1,315 on the confirmation) while produced went up; (2) the confirmation labels the order size "Completed"; (3) step 2 shows an empty scrollable box under Start Time when no PO is selected; (4) payload types vary (oldProductionOrderProdFinal sent as a number and as a string; unused fields as empty strings).

#### Expected behaviour

Scrap never decreases while a PO runs unless explicitly corrected; the label reads "Order size"; no empty box; numeric fields are sent as numbers and unused fields omitted.

#### Steps to reproduce

1. Run Change PO on L3 (PO 897774) and compare step 1 with the confirmation.
2. Read the label above 20.000 on the confirmation.
3. Open step 2 with no PO selected.

#### Environment

`staging` (CPACK-Staging, L3 and L4, 8 Oct 2026). Components: operator.

#### Causing deploy

Not identified.

#### Severity and impact

Cosmetic and confusing; the scrap change needs explaining because it touches reported quality.

#### Acceptance Criteria

Card-local criteria: this bug is not covered by the spec, so these IDs are local to this card and are not the spec's AC IDs.

- [ ] **BUG-AC-01**: Given a running PO, when Change PO moves from step 1 to the confirmation, then scrap does not decrease unless the operator corrected it.
- [ ] **BUG-AC-02**: The confirmation shows "Order size" for the programmed quantity.
- [ ] **BUG-AC-03**: Step 2 shows no empty box when no PO is selected.
- [ ] **BUG-AC-04**: The setup request sends numbers as numbers and omits unused fields.
- [ ] **BUG-AC-05**: The existing Change PO flows (finish or pause, no new PO; existing PO) keep working.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Related: PRODT-158 (Change PO 500).
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-175](https://packiotdev.atlassian.net/browse/PRODT-175): Events tab: ongoing stops render a dangling "at [-]" end time

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Bug |
| Status | To Do |
| Priority | Low |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | operator |
| Team | Front-end |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

#### Current behaviour

Ongoing stops render their end as "10/07 at 08:26 am - at \[-\]": a dangling "at" and an empty end.

#### Expected behaviour

An ongoing stop reads clearly, for example "10/07 at 08:26 am - ongoing", from the language pack.

#### Steps to reproduce

1. Open the Events tab on a line with an ongoing stop.

#### Environment

`staging` (CPACK-Staging, L3, 7 Oct 2026). Component: operator.

#### Causing deploy

Not identified.

#### Severity and impact

Cosmetic.

#### Acceptance Criteria

Card-local criteria: this bug is not covered by the spec, so these IDs are local to this card and are not the spec's AC IDs.

- [ ] **BUG-AC-01**: Given an ongoing stop, when the Events tab shows it, then the end reads as ongoing in the user's language.
- [ ] **BUG-AC-02**: Closed stops keep their current format.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-177](https://packiotdev.atlassian.net/browse/PRODT-177): Spike: PO 891330 on L6 shows about 250 times its order size

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Spike (Task) |
| Status | To Do |
| Priority | Low |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | packiot-stack-alpha |
| Team | Not set |
| Due date | Not set |
| Labels | discovery |
| Enterprise | C-Pack |

#### Question to answer

Why does PO 891330 on L6 show 7,611,905 produced against an order size of 30,000 (about 250 times)? Is it a PO left running for months, a counting error, or both?

#### Time-box

4 hours.

#### Decision this unblocks

Whether an overproduction warning or a data-correctness Bug is needed.

#### Completion criteria

- [ ] The question has a documented answer, in an ADR, the spec or a comment on this card.
- [ ] The blocked card or decision has been updated with the answer.

#### Expected output

A comment with the cause, and a Bug or Story if one is needed.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-178](https://packiotdev.atlassian.net/browse/PRODT-178): Spike: cause of the CPACK-Staging 502 outage on 8 Oct 2026

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Spike (Task) |
| Status | To Do |
| Priority | Low |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | packiot-stack-alpha |
| Team | Not set |
| Due date | Not set |
| Labels | discovery |
| Enterprise | Not set |

#### Question to answer

What caused CPACK-Staging to return 502 on every endpoint around 12:22 local (15:17 to 15:23 UTC) on 8 Oct 2026: a crash triggered by the failing Change PO requests, or a deploy?

#### Time-box

2 hours.

#### Decision this unblocks

Whether the Change PO 500 can take the API down (severity of PRODT-158).

#### Completion criteria

- [ ] The question has a documented answer, in an ADR, the spec or a comment on this card.
- [ ] The blocked card or decision has been updated with the answer.

#### Expected output

A comment with the server log evidence.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

### [PRODT-179](https://packiotdev.atlassian.net/browse/PRODT-179): Spike: CPACK-Staging stops differ from production (reasons and timestamps)

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Spike (Task) |
| Status | To Do |
| Priority | Low |
| Assignee | Emmanuel Podesta |
| Reporter | Vinícius Silva Silva |
| Components | packiot-stack-alpha |
| Team | Not set |
| Due date | Not set |
| Labels | discovery |
| Enterprise | C-Pack |

#### Question to answer

Why do CPACK-Staging stops differ from production: every L3 stop shows "reason pending" in staging while production has reasons, and timestamps are about one minute earlier in staging?

#### Time-box

4 hours.

#### Decision this unblocks

Whether staging can be used as a parity baseline for downtime features.

#### Completion criteria

- [ ] The question has a documented answer, in an ADR, the spec or a comment on this card.
- [ ] The blocked card or decision has been updated with the answer.

#### Expected output

A comment with the cause; a Bug if mirroring is wrong. Note: test writes on 8 Oct 2026 affected L3 to L6.

#### Evidence and links

* Spec: `docs/specs/PRODT-157-operator-app.md`
* Epic: PRODT-157
* Functional spec and QA notes (Claude doc): Operator App Functional Specification

## Existing item moved under the Epic

### [PRODT-38](https://packiotdev.atlassian.net/browse/PRODT-38): Create Change Production Orders Feature

| Field | Value |
| --- | --- |
| Parent | PRODT-157 |
| Type | Story |
| Status | In Progress |
| Priority | Medium |
| Assignee | William Rodrigues |
| Reporter | Developers PackIOT |
| Components | edge-api, operator |
| Team | Not set |
| Due date | Not set |
| Labels | None |
| Enterprise | Not set |

- [ ] Finish PO
- [ ] Pause PO
- [ ] Start a new PO
- [ ] Use “Create PO” Modal

## Housekeeping outside this Epic

- PRODT-17 and PRODT-52 (cloud Operator) are superseded: close them manually with resolution Won't Do (a comment on each asks for it).
- Items in archived projects (PRIMARY-38, PCKT-22, SCRUM-39) were left untouched.
