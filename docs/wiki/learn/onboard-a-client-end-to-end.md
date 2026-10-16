---
title: Onboard a client end to end
layer: 0
owner_area: edge
last_verified: 2026-10-13
---
# Onboard a client end to end

> **Learn · tutorial.** A guided walk through onboarding a factory in CS Admin, from the
> enterprise down to the first OEE number on a dashboard, done safely on the **sandbox** tenant.
> For new Customer Success staff and engineers. Up: [Learn](index.md)

**Goal:** you have built a line in CS Admin, walked every onboarding step, watched live data arrive
and seen OEE computed, without touching a real client.

!!! danger "Sandbox only"
    Do this tutorial **only** in **SANDBOX-CPACK** (enterprise `2000003`) on **staging**. It is a
    throwaway copy of CPACK's configuration that receives a copy of CPACK's live data. Never practise on a
    real client's enterprise, and never on production.

## How the sandbox protects you

```text
 CPACK (enterprise 3) ── live data ──► oeecloud-fanout ──► SANDBOX-CPACK (enterprise 2000003)
                                                              │ you edit it in CS Admin
                                                              ▼
                     your first change starts a "session": nightly reset is held
                     4 h after your LAST change ─► automatic heal back to a copy of CPACK
```

- Every id in the sandbox is CPACK's id + 2,000,000, so nothing collides with the real tenant.
- Your first change in the sandbox starts a **session**: the nightly reset (06:00 UTC) and the
  4-hour heal timer leave your changes alone until 4 hours after your **last** change. Then the sandbox
  is healed back to an exact copy of CPACK's configuration, and your test objects disappear.
- Live telemetry keeps flowing during your session.

The mechanism is `scripts/sandbox-session.sh` (migration `db/migrations/t-sandbox-grace-hold`) and the
`.github/workflows/sandbox-selfheal.yml` workflow; see
[Sandbox twin](../understand/components/sandbox-twin.md). The full rules for testers (addresses,
logins, what a reset removes) are in [Sandbox for testing](../use/sandbox-for-testing.md).

## Before you start

- A CS Admin login in the Cognito group `cs-admin` (an existing CS admin creates it in CS Admin →
  Access → Login accounts, type `cs`).
- Access to Grafana on staging (same SSO).
- Read the plain-language guide once: [Setting up a new client](../use/setting-up-a-client.md). This
  tutorial follows its eight steps.
- Optional, to manage the session yourself: permission to run workflows in the stack repository (`gh`).

## Step 1 · Open the sandbox

1. Open CS Admin on staging: `https://csadmin.staging.packiot.app`.
2. In the enterprise selector at the top, choose **SANDBOX-CPACK**.

**What you should see:** the sites, areas and lines of CPACK (same names; the sandbox is a copy).
**Check the selector before every step:** everything you create goes to the selected enterprise.

On a real onboarding, this step is **Enterprises → new**: the enterprise gets its access key
automatically (`randomUUID()` in edge-api), and you then select it. Skip that here: creating
enterprises is not something to practise.

## Step 2 · Site and area

1. Factory → **Area** → new. Pick one of the sandbox's sites and name the area `TRAINING<yourinitials>`
   (short, no accents, no `-` or `_`: names become part of the data topics and are folded to plain
   ASCII).
2. (A new **Site** would also need a language pack; you can skip it and reuse an existing site.)

**What you should see:** your area in the list, under the site you picked.

## Step 3 · A line and two machines

1. Factory → **Lines** → new: `L99` in your area.
2. Factory → **Machines** → new, twice, both with parent line `L99`:
    - `INFEED` — counts what goes in (gross);
    - `OUTPUT` — counts good units out (net). Set **Production speed** to `120` (units per minute):
      this is the line's lead machine, and its rated speed is what Performance is measured against.
3. Leave the other fields at their defaults (running ≥ 85 % of rated speed, stopped < 30 %, short
   stop < 60 s).

**What you should see:** the line with two members. The page you create from decides the type: Lines
makes a line (`tp_equipment` 3), Machines a machine (`tp_equipment` 1).

## Step 4 · Shifts

1. Factory → **Shift** → new, scoped to your area: code `A`, Monday–Friday, 06:00–14:00. Add `B`,
   14:00–22:00.

**What you should see:** the shifts with the times you typed. Without shifts there is no OEE at all:
OEE is counted per shift.

## Step 5 · Walk the onboarding wizard

Open **Onboarding** (`/app/onboarding`). The steps unlock in order; the active step is in the URL.

| Wizard step | In the sandbox | On a real client |
|---|---|---|
| 1 · Set up the client box | **Read it, don't click *Mint activation*.** There is no box behind the sandbox | Create the one-time setup command, someone at the factory runs it once as root on the box, then *Check connection* until **Online** ([First-time box setup](../build/operate/first-time-box-setup.md)) |
| 2 · Review the plant | Look at the tree: find your line and the topic derived for each machine | Check every name; answer "Do you control this factory's PLC numbering?" (usually *No*) |
| 3 · Connect the PLCs | Open the PLC connections, sensor tags and sensor config per line. **Don't save**: the sandbox's descriptor mirrors CPACK's and is re-copied at heal | One row per PLC (IP, protocol, **Test**); per machine, which counter is gross, net, scrap |
| 4 · Set up shifts | Already done in step 4 | Same |
| 5 · Go live (dry run) | **Don't Build or Deploy** | *Build* generates the box settings; *Deploy* sends them to the box over SSM |
| 6 · Confirm counts are real | Read the counter classes | Watch live data; each counter is `confirmed`, `mismatch`, `unobserved`, `derived` or `extra` |
| 7 · Flip it on | Read the readiness list: your `L99` shows what a real line without data would block on | Fix every red item, then confirm. Reversible (Reset) |
| 8 · Promote to production | Read only. *Apply* is disabled everywhere | Production cut-overs follow client runbooks |

The technical version of every step, with the API calls behind it, is
[Onboarding a client (for engineers)](../build/operate/onboarding-a-client.md#b-run-the-onboarding-wizard).

## Step 6 · Watch data arrive

Your `L99` has no box, so it gets no data. The sandbox's copied CPACK lines do: use them to learn what
"data arriving" looks like.

1. Open Grafana → **🔎 Ingest debug — why isn't a client's data arriving?**
   ([direct link](https://grafana.staging.packiot.app/d/aud-debug-ingest)) and pick **Client (tenant)**
   `sbxcpack`.
2. Read the panel **① Read me first — the decision tree**, then follow the rows top to bottom:
    - **② Source** — is anything arriving at the broker?
    - **③ Queue** — `Queue depth`, `Consumers` for the tenant: depth near 0 and at least one consumer;
    - **④ Worker** — `Write rate by result` is *the* end-to-end signal: a steady rate of successful writes;
    - **⑤ Landing & mapping** — `Silver freshness by client` should be minutes, not hours;
      `Unmapped topics` should be empty.
3. In CS Admin, the equipment page's **Topology** tab shows how recently each machine sent data.

**What you should see:** the sandbox writing continuously, a few seconds behind CPACK. Switch the picker
to another tenant to compare.

On a real client, this is where a wrong IP, an offline box or an unmapped topic shows up. The
[Troubleshooting OEE](../use/troubleshooting-oee.md) page walks each case.

## Step 7 · See OEE

1. Open Grafana → **① CS · Client health** ([direct link](https://grafana.staging.packiot.app/d/aud-cs)).
2. Row **③ OEE — business health per client**: find the sandbox in **OEE by client (last 24h, producing
   shifts)** and **OEE trend by client (hourly)**, and check **OEE freshness — latest completed shift by
   client**.

**What normal looks like in the first hour of a new line:**

| Time after data starts | What you should see |
|---|---|
| Seconds | Data in Ingest debug's write rate and silver freshness |
| ~1–2 minutes | The current hour's OEE row exists and fills in (hourly rows update about every minute) |
| ~2 minutes | The current shift's row follows |
| End of the hour | The hourly trend gets its first complete point |
| End of the first shift | **OEE freshness** shows a completed shift |

The first hour is often partial (the line started mid-hour), so its OEE can look low. That is expected.
Timings: [A counter's journey](../understand/architecture/data-journey.md#hop-by-hop).

## Step 8 · Finish the session

When you are done, either leave it (the sandbox heals 4 hours after your last change), or reset it now:

```bash
gh workflow run sandbox-selfheal.yml -R packiot/packiot-stack-alpha -f action=status
gh workflow run sandbox-selfheal.yml -R packiot/packiot-stack-alpha -f action=heal-now
```

Need more time? `-f action=extend -f duration=8h`.

## Check it worked

- You built an area, a line with two machines, and two shifts, and saw them in **Review the plant**.
- You can explain what each wizard step does on a real client, and which ones you skipped here and why.
- You found the sandbox in Ingest debug with a steady write rate, and in CS · Client health with OEE.
- After `heal-now` (or 4 hours), `TRAINING<yourinitials>` is gone from the sandbox.

## If it went wrong

| Symptom | Likely cause | What to do |
|---|---|---|
| You created something in the wrong enterprise | The selector was not on SANDBOX-CPACK | Stop. If it is a real client, tell the platform team at once; do not try to clean up by hand |
| Your changes vanished during the tutorial | The session expired (4 h after your last change) or someone ran `heal-now` | Start again; use `extend` next time |
| The wizard says a step is locked | An earlier step is not complete | The locked step names which one |
| `sbxcpack` is missing from the Ingest debug picker | The fanout or the sandbox's consumer is down | Tell the platform team; see [ingest-shim & fanout](../understand/components/ingest-shim-and-fanout.md) |

## Next

- [Setting up a new client](../use/setting-up-a-client.md) — the same steps for a real client, in plain words.
- [Onboarding a client (for engineers)](../build/operate/onboarding-a-client.md) — making OEE compute,
  access, the readiness codes.
- [Customizing a client](../use/customize/index.md) — calculations and settings after go-live.
- [Your first week](first-week.md) — the engineering tutorial.
