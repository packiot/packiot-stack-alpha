---
title: OEE settings
layer: guide
owner_area: frontends
last_verified: 2026-09-29
---
# OEE settings

> For the **automation team**. How OEE is calculated for one client, and for single lines.
> Up: [Customizing a client](index.md)

## The one question per line

**OEE = Availability × Performance × Quality** (see the example on [Start here](../../index.md)).
To know **Availability**, Packiot must know when a line was running. There are two ways:

| The line… | Choose | How "running" is decided |
|---|---|---|
| sends its own running / stopped signals | **Its own signals** | From those signals |
| only counts parts | **Its lead machine** | The line is running while its **lead machine** (the main machine that counts the line's output) is counting |

On **Customize → OEE settings**:

1. **Default for all lines** — pick the answer that fits most lines of this client.
2. **Per line** — each line shows **Default (…)**, **Its lead machine** or **Its own signals**.
   Change only the lines that are different.
3. **Save**, then **Apply now**.

A line without a lead machine can't use "Its lead machine" — set one first in **CS Admin →
Line configuration**.

Example: a client's lines send running/stopped signals, except **Line 3**, which only has a
counter. Default = **Its own signals**; Line 3 = **Its lead machine**.

## Ignore impossible counter jumps

A counter can jump (a PLC restart, a counter reset). If a jump would mean the machine made
parts faster than **X times its ideal speed**, Packiot treats it as a glitch. Leave it
empty to use the platform default; typical values are 3 to 5.

## When do changes apply?

- **Apply now** restarts the OEE calculator (a few seconds, no data lost).
- New results use the new settings **from that moment on**.
- **Past results don't change.** To recalculate the past for some lines and dates, ask the
  platform team for a recompute.
