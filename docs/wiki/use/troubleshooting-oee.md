---
title: Troubleshooting OEE
layer: guide
owner_area: compute
last_verified: 2026-10-13
---
# Troubleshooting OEE

> **Use Packiot.** What to do when an OEE number looks wrong: what you see, the usual reasons,
> what to check yourself, and when to call the platform team. For the automation team and
> Customer Success. Up: [Use Packiot](index.md)

!!! note "Which system are you looking at?"
    Everything on this page is about the **new Packiot platform**. Today it runs on **staging**:
    Grafana at `grafana.staging.packiot.app`, CS Admin and Customize on `*.staging.packiot.app`.
    Most clients in **production** still use the **old system** (the one at `go.packiot.com`).
    If a client complains about a number in the old system, this page does not apply: send it
    to the platform team.

## How OEE is built, in everyday words

OEE is three percentages multiplied together. Each one answers one question about a shift
(or an hour, a day…). The full worked example is on [Start here](index.md#oee-in-one-example).

| Factor | Question | How Packiot gets it |
|---|---|---|
| **Availability** | Was the line running? | Running time ÷ planned time. Never more than 100 %. |
| **Performance** | When it ran, did it run at full speed? | Parts that went **in** ÷ (rated speed × running minutes) |
| **Quality** | Were the parts good? | **Good** parts out ÷ parts that went **in** |
| **OEE** | All together | Availability × Performance × Quality |

So OEE depends on four things being right: **the counters** (what went in, what came out), **the
rated speed** of the line, **the shifts** (planned time), and **knowing when the line ran**.
Almost every problem below is one of those four.

Three rules that explain a lot of "strange" numbers:

- **Packiot shows the real number.** Performance and Quality can go **above 100 %**. That is not a
  bug: it means a setting or a counter is wrong, and Packiot shows it so you can fix it.
- **Time without data is not a stop.** When the factory box tells us it could not read the PLC,
  that time is marked **No data**: it is neither running nor stopped, and it is left out of
  Availability.
- **Changing a setting does not change the past.** New settings apply from the moment you save.
  To fix past days, ask the platform team for a recompute (see
  [OEE settings](customize/oee-settings.md#when-do-changes-apply)).

## The two dashboards you will use

Both are in Grafana on staging (company login).

| Dashboard | Use it to answer | What to look at |
|---|---|---|
| [① CS · Client health][g-cs] | "Is this client OK overall?" | **Live data freshness by client** (is data arriving now?), **OEE by client (last 24h)**, **OEE freshness — latest completed shift by client** (is OEE still being calculated?) |
| [🔎 Ingest debug][g-ingest-debug] | "Why is this client's data not arriving?" | Pick the client at the top (**Client (tenant)**: `cpack`, `bispharmastaging`, `sbxcpack`…). Read the tiles **top to bottom**; the first red tile is where it broke. The **Read me first** box explains each case. |

In **CS Admin** there is one more quick check: open the client's **Lines** (or **Machines**) page
and switch to the **Topology** tab. Each machine has a dot:

| Dot | Meaning |
|---|---|
| green | sending data (last data less than 5 minutes ago) |
| grey | quiet: sent data in the last 2 hours, but not in the last 5 minutes |
| red | no data in the last 2 hours: check the machine and its connection |

---

## OEE is 0 %

**What you see:** a line shows 0 % OEE for a shift or an hour.

First ask: **was the line really producing?** A line that was stopped the whole shift has 0 %
Availability, so 0 % OEE is the right answer.

| Likely cause | What to check | Fix |
|---|---|---|
| The line was really stopped | Ask the client, or look at the line's stops for that shift in front4 | Nothing: the number is right |
| No rated speed on the lead machine | CS Admin → the line's **lead machine** → **Production speed** is empty | Set it (see [Setting up a client → Lines and machines](setting-up-a-client.md#step-4-lines-and-machines)) |
| The "parts in" or "good parts" counter never moves | CS Admin → **Topology** tab: is the machine green? Then check which counter is set as gross and net ([Connect the PLCs](setting-up-a-client.md#step-6-plc-connections)) | Fix the sensor tag, or ask the client's integrator what each counter means |
| No data at all for the line | See [No data for a line](#no-data-for-a-line) | — |

!!! info "Blank is not 0"
    For clients whose counters are only at the **line** level, single machines have no OEE of their
    own. Packiot shows those machines as **blank / not metered**, not as 0 %. That is expected.

**Call the platform team when:** the line was producing, it has a rated speed, its counters are
green, and OEE is still 0 %.

## No data for a line

**What you see:** empty charts, or the numbers stop at some time and do not move.

| Likely cause | What to check | Fix |
|---|---|---|
| No shifts for that day or time | CS Admin → **Shift**: does a shift cover that time? Without shifts the dashboards stay empty | Create or fix the shift ([Shifts](setting-up-a-client.md#step-5-shifts)) |
| The factory box is off or has no internet | CS Admin → **Topology** tab: are **all** machines of the client red? [Ingest debug][g-ingest-debug] stage ④ **Write rate** is flat 0 and stage ③ **Queue depth** is 0 (nothing arriving) | Ask the client if the box has power and internet. Then call the platform team |
| The box is fine but cannot read one PLC | Only the machines of that PLC are red; the others are green | Ask the client if the PLC is on and its cable or network changed. The time shows as **No data** |
| The line is out of service on purpose | CS Admin → **Factory → Lines** → the line's settings → **Out of service** card lists a period that covers these days | Nothing, if it is intended. Out-of-service days are left out of OEE and of the production target. Remove the period if it is wrong |
| Data arrives but Packiot does not know where it belongs (setup not finished) | [Ingest debug][g-ingest-debug] stage ⑤ **Unmapped topics** shows bars | Finish the PLC and machine setup in CS Admin, or call the platform team |
| Data arrives but OEE stopped being calculated | [CS · Client health][g-cs] → **OEE freshness**: the age keeps climbing, while **Live data freshness** is fine | Call the platform team: the calculation has stopped |

**What to send the platform team:** client name, line name, the time it stopped (factory time),
and a screenshot of the [Ingest debug][g-ingest-debug] dashboard for that client.

## Performance above 100 %

**What you see:** Performance is 110 %, 150 %, sometimes much more.

Performance compares how many parts went in with what the **rated speed** says was possible in the
running time. Above 100 % means "more parts than the rated speed allows".

| Likely cause | What to check | Fix |
|---|---|---|
| The rated speed is too low | Ask the client for the nameplate speed of the line and compare with **Production speed** on the lead machine | Correct the speed. Only new results change; ask for a recompute for past days |
| A counter jumped (PLC restart, counter reset) | Is it one hour or one shift only, with a huge value? | Packiot screens out impossible jumps by itself (the old **Ignore impossible counter jumps** setting is retired). If one still got through, call the platform team |
| Running time is too short (the line ran but Packiot thought it was stopped) | Compare with the line's stops: are there stops while the line was producing? | Check how "running" is decided for this line: **Its own signals** or **Its lead machine** ([OEE settings](customize/oee-settings.md#the-one-question-per-line)) |

!!! tip "The client health averages skip these shifts"
    The **OEE by client (last 24h)** table on [CS · Client health][g-cs] averages only shifts where every
    factor is between 0 and 100 %. A shift with Performance above 100 % does not appear in that average.
    Look at the line itself in front4 to see it.

## Quality looks wrong

**What you see:** Quality above 100 %, or much lower than the client expects.

Quality = good parts out ÷ parts in. It depends only on the two counters.

| What you see | Likely cause | Fix |
|---|---|---|
| Above 100 % for a whole shift or day | "Parts in" and "good parts" counters are **swapped**, or a station in the **middle** of the line is set as the output | Fix the sensor tags ([Connect the PLCs](setting-up-a-client.md#step-6-plc-connections)). The PLC gives numbers, not meanings: ask the client's integrator |
| A bit above 100 % in a single **hour**, normal for the shift | Parts that entered at the end of one hour come out in the next hour | Normal. Look at the shift or day instead |
| Much too low | The scrap counter or the "parts in" counter counts something else (for example, it counts twice), or scrap is calculated as in − out but there is a buffer between them | Check the counters with the client. A scrap formula is changed in **Customize → Calculations** ([Calculations](customize/calculations.md)) |

## A stop has no reason

**What you see:** a stop shows without a reason (no category).

| Likely cause | What to check | Fix |
|---|---|---|
| The operator did not give a reason yet | The stop is recent | Operators give the reason in the **Operator app** on the tablet. Remind the client |
| The client's list of reasons is empty or missing the right one | CS Admin → **Downtime Reasons** | Add the reasons the client uses |
| The stop is on a single machine, but the client looks at the line | For lines that only count parts, a line's stops come from its **lead machine** | Check the line's lead machine in CS Admin. If line stops are still missing, call the platform team (this is set per line on our side) |
| Very short stops | Stops shorter than the short-stop limit are counted as short stops, not as normal stops (the limits are on the machine; see [Lines and machines](setting-up-a-client.md#step-4-lines-and-machines)) | Normal |

Time marked **No data** (PLC not readable) is **not** a stop, so it never asks for a reason.

## Numbers differ from the old system

**What you see:** the client (or you) compares the new Packiot with the old system and the
numbers are not the same.

Some difference is expected. Before you call it a bug, check these:

| Check | Why |
|---|---|
| **Compare the same thing.** Same line, same days, same hours, in **factory time** (Brasília). Compare **lines by hour** and **machines by their counters** | The old system's **hourly** numbers and raw counters are reliable. Its **shift** totals are known to be lower than its own hourly totals by several percent, so a shift comparison will often show the new system higher |
| **Same rated speed?** | A different rated speed in the two systems changes Performance and OEE, even with the same parts counted. Some lines are deliberately configured differently |
| **Performance above 100 %** | The old system often stopped Performance at 100 %. The new one shows the real value (see [above](#performance-above-100)) |
| **No data time** | The new system leaves time without data out of Availability; the old one may have counted it as a stop |
| **Past days after a settings change** | New settings apply only from the moment you save. Past days keep the old calculation until a recompute |

**Call the platform team when:** the **hourly** numbers of a **line** differ by more than a few
percent on the same hours, with the same rated speed. Send: client, line, the hours you compared,
and both numbers.

More detail for engineers: [Comparing with legacy](../understand/architecture/domain-model.md#comparing-with-legacy).

---

## Who to call, and what to send

| Situation | Who | Send |
|---|---|---|
| Box offline, PLC unreadable, counters wrong | The **client** first (power, internet, PLC, integrator) | — |
| Setup question (shifts, speeds, counters, reasons) | Fix it yourself in CS Admin / Customize | — |
| Everything above looks right and the number is still wrong | The **platform team** | Client, line, time window (factory time), what you expected and what you see, a screenshot of [CS · Client health][g-cs] or [Ingest debug][g-ingest-debug] |
| Recompute past days after a fix | The **platform team** | Client, lines, dates, what was fixed |

Engineers on call use the [Runbooks](../build/operate/runbooks.md). Words you don't know are in the
[Glossary](../reference/glossary.md).

## Next

- [Setting up a new client](setting-up-a-client.md) — where most of these settings live.
- [OEE settings](customize/oee-settings.md) — how "running" is decided for each line.
- [Calculations](customize/calculations.md) — change how scrap or a line total is calculated.

[g-cs]: https://grafana.staging.packiot.app/d/aud-cs
[g-ingest-debug]: https://grafana.staging.packiot.app/d/aud-debug-ingest
