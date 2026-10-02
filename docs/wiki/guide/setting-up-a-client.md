---
title: Setting up a new client (CS Admin)
layer: guide
owner_area: frontends
last_verified: 2026-09-29
---
# Setting up a new client (CS Admin)

> For **Customer Success**. How to bring a new factory into Packiot with **CS Admin**, step
> by step, in plain words. Up: [Start here](../index.md) · Technical version:
> [Onboarding a client (for engineers)](../operations/onboarding-a-client.md)

## The idea

You describe the factory **once**: its sites, areas, lines, machines, shifts and PLCs. From
that description Packiot builds everything else by itself: the settings for the factory box,
the names the data arrives under, and the places where OEE is stored. You never type a
technical address by hand.

Do the steps **in this order**. Each step hangs on the one before it: a machine needs a
line, a line needs an area, and so on.

```text
 1 Client ─► 2 Sites ─► 3 Areas ─► 4 Lines & machines ─► 5 Shifts
                                                           │
            8 Go live ◄─ 7 Factory box ◄─ 6 PLC connections ◄┘
```

The factory box (step 7) takes the longest, because someone at the client has to install it.
You can start it early and continue with the other steps while you wait.

## Before you start

Ask the client for:

| What | Why | Example |
|---|---|---|
| List of sites, lines and machines, with the names they use | They become the names in Packiot | Site "SP", line "L01", machines "Filler", "Capper" |
| For each line: its rated speed | Needed for Performance | 120 bottles per minute |
| Shift times | OEE is counted per shift | Shift A 06:00–14:00, Mon–Fri |
| For each PLC: its IP address and brand/protocol | So the box can read it | `192.168.10.15`, Siemens S7 |
| What each PLC counter **means** | Which counter is "what went in", "good parts", "scrap" | Counter 1 = bottles in, counter 2 = bottles out |
| A small Linux computer on site that reaches the PLCs **and** the internet | This becomes the factory box | See [First-time box setup](../operations/first-time-box-setup.md) |

!!! tip "Practice first"
    There is a **sandbox** copy of a real client for practice. Try anything risky there
    first. Ask the platform team which one to use.

## Step 1 · Client

**What it is:** the company. In CS Admin it is called an **Enterprise**.

**How:** CS Admin → **Enterprises** → new. Give it the name you want to see everywhere, for
example `ACME`. Keep the default time zone unless the factory is in another one. Packiot
creates the client's access key by itself; you never type or copy it.

**After saving:** choose the new client in the selector at the top of CS Admin. Every page
after this works on the selected client.

**What can go wrong:** you forget to switch the selector and create sites under the wrong
client. **How to tell:** the site list shows sites you do not recognize. Check the selector
before each step.

## Step 2 · Sites

**What it is:** one factory building or location. A client can have several.

**How:** Factory → **Site** → new. Use a short name, for example `SP` rather than
"São Paulo plant". Choose a language pack (you cannot save without one).

**What can go wrong:** long names with accents and symbols. Packiot removes accents, `-` and
`_` from names ("Linha-01" becomes "Linha01"). This is fine, but choose short, clear names
from the start. Renaming later is harder.

## Step 3 · Areas

**What it is:** a section of a site, for example "Packaging" or "Lines".

**How:** Factory → **Area** → new. Pick the site it belongs to.

**Example:** site `SP`, area `LINHAS`.

## Step 4 · Lines and machines

**What they are:** a **line** is a full production line. A **machine** is one station on it
(filler, capper, labeller). Each machine belongs to one line.

**How:**

1. Factory → **Lines** → one entry per line, for example `L01`.
2. Factory → **Machines** → one entry per machine. Pick its line.
3. On the machine at the **end** of the line (the one that counts finished products), set
   **Production speed**: the rated speed in units per minute. This machine is the line's
   **lead machine**; its speed is the one Performance is measured against.

Leave the other fields at their default values unless the client asks otherwise. The
defaults say: a machine is "running" at 85 % or more of its rated speed, "stopped" below
30 %, and a stop shorter than 60 seconds is a short stop.

**Example:** line `L01` with machines `INFEED` (counts bottles going in) and `OUTPUT` (counts
good bottles going out). `OUTPUT` has production speed 120.

**What can go wrong:**

| Problem | How to tell | Fix |
|---|---|---|
| No production speed on the lead machine | Go live (step 8) shows the error "missing ideal speed" | Set production speed on that machine |
| Two machines with the same name on the same line | Go live shows "duplicate equipment" | Rename one. The same name on **different** lines is fine |
| Wrong speed | Performance far above or below what the client expects | Ask the client for the nameplate speed and correct it |

## Step 5 · Shifts

**What it is:** when the factory works. OEE is counted per shift, so **without shifts the
dashboards stay empty**.

**How:** Factory → **Shift** (or step "Set up shifts" in **Onboarding**). Give the shift a
code (`A`, `T1`, `MORNING`), switch on its weekdays and type start and end times.

**Example:** `A` Mon–Fri 06:00–14:00, `B` Mon–Fri 14:00–22:00.

**What can go wrong:**

| Problem | How to tell | Fix |
|---|---|---|
| No shifts at all | Dashboards stay empty after go-live | Create at least one shift |
| A shift that crosses midnight (22:00–06:00) | After saving, the shift shows other times than you typed, or the day shows gaps | Open the shift again and check it; if it is wrong, ask the platform team |
| Shifts overlap | The same hour is counted twice | Make each shift end where the next one starts |

Optional but useful now: **Teams**, **Downtime Reasons** (the list operators pick from when a
machine stops) and **Production Targets** (a default target is created for each new line).

## Step 6 · PLC connections

**What it is:** telling Packiot where each PLC is and what each counter means.

**How:** **Onboarding** → step "Connect the PLCs".

1. **PLC connections:** one row per PLC: a name, its IP address and its protocol (Siemens
   S7, Modbus TCP or OPC-UA). Use **Test** to check the address.
2. **Sensor tags:** for each machine, which PLC counter is "what went in" (gross), "good
   parts" (net) and "scrap".
3. **Sensor config per line:** which counters the line really has, for example "only in and
   out; scrap = in − out".

**Example:** PLC `S7 L01` at `192.168.10.15`. Counter at address `DB1,DINT0` = INFEED,
gross. Counter at `DB1,DINT20` = OUTPUT, net.

!!! warning "The PLC tells you numbers, not meanings"
    Watching live values shows which counters move, but not what they count. A station in
    the middle of the line can move faster than the output. Always get the meaning from the
    client's integrator or from their existing PLC program. A wrong choice here makes
    Quality look higher than 100 %.

!!! note "Coming soon"
    A switch in CS Admin to turn reading a single PLC on and off. Today, ask the platform
    team.

## Step 7 · Factory box

**What it is:** the small computer on site that reads the PLCs and sends the counts to the
cloud. The cloud reaches it over a secure channel that the box opens itself, so the client
does not need to open any firewall port.

**How:** **Onboarding** → step "Set up the factory box".

1. Check the requirements shown on the page with the client's IT.
2. Create the **one-time setup command** on that page. It is shown once, so copy it.
3. Someone at the client runs that command on the box.
4. Click **Check connection** until the box shows **Online**.

**What can go wrong:** the box never comes Online. Usually the box has no internet access, or
the command was run twice or too late. Create a new setup command and try again. Full details:
[First-time box setup](../operations/first-time-box-setup.md).

## Step 8 · Go live

**How:** **Onboarding**, the last steps, in order:

1. **Review the plant:** a tree of everything you created. Check the names. Answer the
   question "Do you control this factory's PLC numbering?" (usually **No** for an existing
   factory).
2. **Install on the factory box:** **Build the setup**, then **Install on the factory box**.
   Packiot prepares the box's settings and sends them to the box. Nothing changes for the
   client yet.
3. **Confirm counts are real:** start watching live data, let the box send live data for a few
   minutes, then read the report. Each counter is marked:

    | Mark | Meaning | What to do |
    |---|---|---|
    | confirmed | seen where expected | nothing |
    | mismatch | seen on a different counter | fix the sensor tag (step 6) |
    | unobserved | never moved | check the sensor or PLC with the client; maybe the line is stopped |
    | derived | calculated, not read (for example scrap = in − out) | nothing |
    | extra | the PLC sends a counter you did not configure | usually ignore; check it is not a missed machine |

4. **Go live:** the page lists anything that still blocks (red) or deserves a look
   (yellow), each with a link to the fix. When nothing is red, confirm. From now on the data
   counts. This step can be undone (Reset on the Onboarding page).

**How to tell it worked:** within the next shift, front4 shows OEE for the client's lines.

| Symptom | Likely cause |
|---|---|
| Dashboards empty | No shifts (step 5), or the client is not yet enabled for OEE on our side: ask the platform team |
| Quality above 100 % | Gross and net are swapped, or a middle station is set as the output (step 6) |
| Performance above 100 % | Rated speed too low (step 4) |
| A client user sees an empty front4 | The user's role lists no lines: CS Admin → Access → Users & Roles |

## Give people access

In CS Admin → **Access**:

- **Login Users** creates the person's login.
- **Users & Roles** / **Roles** decides which lines and pages they see. A role with no lines
  shows an empty front4.
- Operators also need their email as their user name.

## After go-live

Changes to how numbers are calculated for this client (a scrap formula, a line total, an
alert) are made in the **Customize** app, not in CS Admin. See
[Customizing a client](customize/index.md).
