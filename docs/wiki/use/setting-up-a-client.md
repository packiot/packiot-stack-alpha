---
title: Setting up a new client (CS Admin)
layer: guide
owner_area: frontends
last_verified: 2026-10-13
---
# Setting up a new client (CS Admin)

> For **Customer Success**. How to bring a new factory into Packiot with **CS Admin**, step
> by step, in plain words. Up: [Start here](index.md) · Technical version:
> [Onboarding a client (for engineers)](../build/operate/onboarding-a-client.md)

## The idea

You describe the factory **once**: its sites, areas, lines, machines and shifts. Then the
**Onboarding** page walks you through connecting the factory box and the PLCs and switching
the client on. From your description Packiot builds everything else by itself: the settings
for the factory box, the names the data arrives under, and the places where OEE is stored.
You never type a technical address by hand.

There are two parts, done **in this order**:

```text
 Part A · describe the factory (menu "Factory")
   Client ─► Site ─► Area ─► Lines ─► Machines ─► Shifts

 Part B · the Onboarding page (8 steps, left to right)
   1 Set up the factory box ─► 2 Review the plant ─► 3 Connect the PLCs ─► 4 Set up shifts
      ─► 5 Install on the factory box ─► 6 Confirm counts are real ─► 7 Go live
      ─► 8 Copy to production
```

Each piece hangs on the one before it: a machine needs a line, a line needs an area, and so
on. The factory box (Onboarding step 1) takes the longest, because someone at the client has
to install it. Start it early; you can review the plant while it connects.

!!! note "Staging first"
    New clients are set up on the **test system (staging)** first. Step 8 copies the finished
    setup to the real system (production). Most clients in production still run on the old
    platform; ask the platform team before you use step 8.

## Before you start

Ask the client for:

| What | Why | Example |
|---|---|---|
| List of sites, lines and machines, with the names they use | They become the names in Packiot | Site "SP", line "L01", machines "Filler", "Capper" |
| For each line and machine: its rated speed | Needed for Performance | 120 bottles per minute |
| Shift times | OEE is counted per shift | Morning 06:00–14:00, Mon–Fri |
| For each PLC: its IP address and brand/protocol | So the box can read it | `192.168.10.15`, Siemens S7 |
| What each PLC counter **means** | Which counter is "what went in", "good parts", "scrap" | Counter 1 = bottles in, counter 2 = bottles out |
| A computer on site that reaches the PLCs **and** the internet | This becomes the factory box | See [First-time box setup](../build/operate/first-time-box-setup.md) |

!!! tip "Practice first"
    There is a **sandbox** copy of a real client for practice (see
    [sandbox twin](../reference/glossary.md)). Try anything risky there first. Ask the
    platform team which one to use.

## Part A · Describe the factory

### Client

**What it is:** the company. CS Admin calls it an **Enterprise**.

**How:** on the **Enterprises** page (the first page after you log in), click **Add
enterprise**. Fill in **Client (company) name** and **Timezone**, and keep the other
defaults unless the client asks otherwise. Packiot creates the client's access key by
itself; you never type or copy it.

**After saving:** click the new client in the list. Every page after this works on that
client. Its name is shown at the top of CS Admin; **Switch client** takes you back to the
list.

**What can go wrong:** you are on the wrong client and create sites there. **How to tell:**
the site list shows sites you do not recognize. Check the name at the top before each step.

### Site

**What it is:** one factory building or location. A client can have several.

**How:** **Factory → Site → New Site**. Fill in **Site name**, **Language shown to the
factory team** (you cannot save without it) and **Timezone**.

**Naming:** use short names, for example `SP` rather than "São Paulo plant". For the data
addresses Packiot turns names into capitals and removes accents, spaces and symbols
("Linha-01" becomes `LINHA01`). This is fine, but short, clear names from the start avoid
surprises. Renaming later is harder.

### Area

**What it is:** a part of a site where production lines sit, for example "Packaging hall".

**How:** **Factory → Area → New Area**. Give it an **Area name** and pick its **Site**.

### Lines and machines {#step-4-lines-and-machines}

**What they are:** a **line** is a full production line. A **machine** is one station on it
(filler, capper, labeller). Each machine belongs to one line. (A **sector** is a group of
machines inside a line; most clients do not need sectors.)

**How:**

1. **Factory → Lines → New Line**, one per line, for example `L01`.
2. **Factory → Machines → New Machine**, one per machine. Pick the line in **Belongs to
   line / sector**.
3. Fill **Production speed (units/min)**: the rated speed. The form asks for it on every line
   and machine.
4. Back on **Factory → Lines**, press the settings button on the line (**Choose this line's
   machines and counters**). On the **Line settings** page:
    - check the list under **Machines on this line** and their order;
    - pick the **Main machine — counts good items**: the machine at the end of the line that
      counts finished products. It also reports the line's stops. This is the line's
      **lead machine**;
    - pick the machines that count everything made (gross) and scrap, or press **Choose
      automatically from sensors**;
    - press **Save line settings**.

Leave the other machine fields at their defaults unless the client asks otherwise. The
defaults say: a stop longer than **60 seconds** is downtime that needs a reason (shorter is a
small stop), a machine is **running normally from 85 %** of its production speed and
**stopped below 30 %**, and stops are detected on a **5-minute average** of the speed.

**Example:** line `L01` with machines `INFEED` (counts bottles going in) and `OUTPUT` (counts
good bottles going out). `OUTPUT` is the main machine, with production speed 120.

**What can go wrong:**

| Problem | How to tell | Fix |
|---|---|---|
| No production speed | The go-live check lists "no ideal speed" with a **Set ideal speed** button | Set production speed on that machine |
| Two machines with the same name on the same line | The go-live check lists a duplicate | Rename or delete one. The same name on **different** lines is fine |
| Wrong speed | Performance far above or below what the client expects | Ask the client for the nameplate speed and correct it ([Performance above 100 %](troubleshooting-oee.md#performance-above-100)) |

**Out of service:** the **Line settings** page also has an **Out of service** card. Use it
for days a line is not in use **on purpose** (not started yet, waiting for its PLC, stopped
for good): pick **First day**, optionally **Last day** (empty = until further notice), write a
**Reason** and press **Add period**. Those days are left out of the line's OEE and its
production target. A line that should be running but is not is **not** out of service.
Changes there save straight away.

### Shifts {#step-5-shifts}

**What it is:** when the factory works. OEE is counted per shift, so **without shifts every
OEE number stays blank**.

**How:** **Factory → Shifts → New Shift** (or Onboarding step 4). Give it a **Shift name**
(`A`, `T1`, `MORNING`), tick its days and type the start and end times. **Only for one site
or area (optional)** limits it to one site or area.

**Example:** `A` Mon–Fri 06:00–14:00, `B` Mon–Fri 14:00–22:00.

| Problem | How to tell | Fix |
|---|---|---|
| No shifts at all | Dashboards stay blank after go-live | Create at least one shift |
| A shift that crosses midnight (22:00–06:00) | After saving, the shift shows other times than you typed, or the day shows gaps | Open the shift again and check it; if it is wrong, ask the platform team |
| Shifts overlap | The same hour is counted twice | Make each shift end where the next one starts |

Optional but useful now: **Teams**, **Downtime reasons** (the list operators pick from when a
machine stops) and **Production targets** (how many units per hour, day, week and month).

## Part B · The Onboarding page

Open **Onboarding** in the menu. The steps run left to right; a step opens once the steps it
depends on are done. **Start over** (top of the page) takes the client back to step 1 and
keeps your list of lines and machines.

### 1 · Set up the factory box

**What it is:** the small computer on site that reads the PLCs and sends the counts to the
cloud. The box opens the connection itself (outgoing port 443), so the client does not need
to open any port into their network.

1. Check **Before you connect it — the factory box must:** with the client's IT (Linux with
   Docker, reaches the PLC network and the internet).
2. Press **Get a setup code**. The command is shown **only once**, so copy it.
3. Someone at the client runs that command **once** on the box.
4. Press **Check connection** until the box shows **Online**, then **Continue to review the
   plant**.

You can press **Skip for now — review the plant while the box connects** and come back.

**What can go wrong:** the box never comes Online. Usually it has no internet access, or the
command was run twice or too late. Press **Get a new setup code** and try again. Full
details: [First-time box setup](../build/operate/first-time-box-setup.md).

### 2 · Review the plant

A list of the client's lines and machines, built from Part A. Check the names. If it says
**Set up lines & machines first**, go back to Part A.

Under **Advanced (rarely needed)**:

- **Do you control this factory's PLC numbering?** **Yes** if Packiot set up the PLCs. **No**
  if the client's PLCs already use their own numbers (usual for an existing factory); then
  step 6 checks each counter against live data.
- **Counters only (no machine-speed sensor):** turn on when the PLCs send counts but no speed
  reading (common on older lines). If you leave it off on such a line, OEE stays at zero.

Press **Confirm & continue**.

### 3 · Connect the PLCs {#step-6-plc-connections}

1. **PLC connections:** one row per PLC (**Add PLC connection**): a name, the protocol
   (**Siemens S7**, **Modbus TCP** or **OPC-UA**) and its address. **Test** checks that the
   factory box can reach it. Press **Save connections**.
2. **Machine counters (where to read them in the PLC):** for each machine, which PLC counter
   is **Good — units coming out (net)**, **Infeed — units going in (gross)** or **Reject —
   units thrown away (scrap)**. Press **Save counters**.
3. **Which sensors does each line have?** tick infeed, good and reject for each line, for
   example "only infeed and good; scrap is calculated". Press **Save sensor setup**.

Each PLC row has a **Reading / Off** switch. **Off** stops reading that PLC but keeps its
settings; it takes effect at the next **Install on the factory box**.

If the client's data already arrives through their own Node-RED (no PLC to read), there is
nothing to fill in here: press **Continue to install on the factory box**.

**Example:** PLC `S7 L01` at `192.168.10.15`. The counter at DB 1, offset 0 is `INFEED`,
gross. The counter at DB 1, offset 20 is `OUTPUT`, net.

!!! warning "The PLC tells you numbers, not meanings"
    Watching live values shows which counters move, but not what they count. A station in
    the middle of the line can move faster than the output. Always get the meaning from the
    client's integrator or from their existing PLC program. A wrong choice here makes
    Quality look higher than 100 %.

### 4 · Set up shifts

Lists the shifts from Part A, or lets you add them here. You may **Skip for now — OEE stays
blank**, but OEE is only calculated during a shift.

### 5 · Install on the factory box

1. **Device keys.** Every machine needs a **device key**: the permanent ID the factory box
   uses to say which machine a number belongs to. If the page shows "machine(s) have no device
   key yet", press **Create missing device keys**. It is safe: existing keys never change.
   **Build the setup** stays off until every machine has one.
2. Press **Build the setup**. Packiot prepares the box's settings and saves the machine
   addresses.
3. Press **Install on the factory box** and confirm. Packiot sends the setup to the box and
   starts it. Nothing is switched on for the client yet.

### 6 · Confirm counts are real

Press **Start capture**, let the box send live data for a few minutes, then read the
report. Each counter is marked:

| Mark | Meaning | What to do |
|---|---|---|
| **Confirmed** | a live reading matched the setup | nothing |
| **Mismatch** | the machine sends a different counter than the setup expects | fix the machine's counter (step 3), or its name fix (step 2, **Advanced → Name fixes**) |
| **Not seen yet** | no data has arrived for it | check with the client that the machine is running and connected |
| **Derived** | no sensor for it, so it is calculated (for example scrap = in − out) | nothing |
| **Unexpected** | the box sends a counter the setup does not list | usually ignore; check it is not a missed machine |

Press **Confirm all observed**, then **Stop capture**.

### 7 · Go live

Two checks:

- **Check 1 of 2 · Setup health (advice only).** Red and yellow items with a button to the
  fix (**Set up shifts**, **Set ideal speed**, **Fix which counter is which**, …). They do not
  block you, but a red item usually means wrong or missing numbers. Fix them first.
- **Check 2 of 2 · Ready to go live (required).** You cannot go live while any machine
  counter is still a **guess**. Confirm them in step 6.

Press **Cut over**, then **Yes, switch it on**. From now on the data counts. It takes effect
the next time the box's data collector restarts. You can undo it with **Start onboarding
over**.

**How to tell it worked:** within the next shift, front4 shows OEE for the client's lines.

| Symptom | Likely cause |
|---|---|
| Dashboards blank | No shifts, or the client is not yet enabled for OEE on our side: ask the platform team |
| Quality above 100 % | Gross and net are swapped, or a middle station is set as the output (step 3) |
| Performance above 100 % | Rated speed too low ([Performance above 100 %](troubleshooting-oee.md#performance-above-100)) |
| A client user sees an empty front4 | The user's role has no lines (see [Give people access](#give-people-access)) |

### 8 · Copy to production

Copies the finished client from staging to production. It shows a preview (a dry run) first;
the real copy needs extra approval and is often switched off. Ask the platform team.

## Give people access

In CS Admin → **Access**:

- **Login accounts → Invite user** creates the person's login. Their email is their user
  name; they get an email with a temporary password. Choose **Client user** and the client.
- **Roles** are job titles at the client (Operator, Supervisor, Manager). **Users** links a
  person to a role.
- **Which lines and pages a role sees** is set in front4: **Settings → Users and
  Permissions**. A role must have at least one line; a user whose role has no lines sees an
  empty front4.

## After go-live

Changes to how numbers are calculated for this client (a scrap formula, a line total, an
alert, how a line's OEE is measured) are made in the **Customize** app, not in CS Admin. Open
it with **Customization Hub ↗** in the CS Admin menu. See
[Customizing a client](customize/index.md).
