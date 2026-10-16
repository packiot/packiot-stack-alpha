---
title: OEE settings
layer: guide
owner_area: frontends
last_verified: 2026-10-13
---
# OEE settings

> For the **automation team**. How OEE is measured for one client, and for single lines.
> Up: [Customizing a client](index.md)

## The one question per line

**OEE = Availability × Performance × Quality** (see the example on
[Use Packiot — start here](../index.md)).

To know **Availability**, Packiot must know when a line was running. There are two ways:

| The line… | Choose | How "running" is decided |
|---|---|---|
| sends its own running / stopped signals | **Its own signals** | From those signals |
| only counts parts | **Its lead machine** | The line is running while its **lead machine** (the main machine that counts the line's output) is counting |

On **OEE settings**, in the box **Where does each line get its data?**:

1. **Default for all lines**: pick **Each line's own signals** or **The line's lead machine**,
   whichever fits most lines of this client.
2. **Per line**: the table lists every line. In **Gets its data from**, each line shows
   **Default (…)**, **Its lead machine** or **Its own signals**. Change only the lines that
   are different.
3. **Save**, then **Apply now**. (Apply now is greyed out while you have unsaved changes.)

A line without a lead machine shows "Its lead machine — no lead machine set" and can't use
it. Set one first in CS Admin: **Factory → Lines** → the line's settings button → **Main
machine — counts good items** → **Save line settings**.

Example: a client's lines send running/stopped signals, except **Line 3**, which only has a
counter. Default = **Each line's own signals**; Line 3 = **Its lead machine**.

## Counter jumps: no setting any more {#ignore-impossible-counter-jumps}

Older versions of this page had a setting to ignore counter jumps above "X times the ideal
speed". It is gone: Packiot handles impossible jumps (a PLC restart, a counter reset) itself,
the same way for every client. If an old value is still stored for a client, the next
**Save** on this page removes it. If a jump still shows up in the numbers, call the platform
team.

## Performance above 100 %

Packiot shows Performance as it really is, also above 100 %; it does not cut it at 100 %.
Above 100 % almost always means the rated speed of the line or its lead machine is set too
low. See [Troubleshooting OEE](../troubleshooting-oee.md#performance-above-100).

## When do changes apply?

- **Apply now** restarts Packiot's OEE calculator in the cloud (a few seconds, no data lost).
  On a test client (a sandbox copy) it says "Test client — nothing was restarted".
- New results use the new settings **from that moment on**.
- **Past results don't change.** To recalculate the past for some lines and dates, ask the
  platform team for a recompute.

| Message | What to do |
|---|---|
| "Someone else saved while you were editing" | Reload the page and make your change again |
| "Could not apply right now" | Try again in a minute, or ask the platform team |
