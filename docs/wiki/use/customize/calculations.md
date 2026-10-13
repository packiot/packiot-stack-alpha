---
title: Calculations
layer: guide
owner_area: frontends
last_verified: 2026-09-29
---
# Calculations

> For the **automation team**. Make a new value from counters the machines already send.
> Up: [Customizing a client](index.md)

## What a calculation is

A machine sends counters: **everything that went in**, **good parts made**, sometimes
**scrap**. A calculation makes a **new counter** out of them. The result is stored like a
real counter, so OEE, the dashboards and the reports all use it.

Typical examples:

| The factory has… | You want… | Formula |
|---|---|---|
| a line that counts what goes in (**a**) and good parts (**b**) | scrap | `a - b` |
| two packing machines on one line (**a**, **b**) | the line total | `a + b` |
| a counter that counts packs of 12 (**a**) | parts | `a * 12` |
| two sensors, take the bigger one | the most reliable count | `max(a, b)` |

## Step by step

1. Open **Customize → Calculations** for the client.
2. **Where does the result go?** Pick the line or machine that owns the new value.
3. **What is the result?** Scrap / rejects, Everything that went in, or Good parts made.
4. **Which values does it use?** Each value gets a letter (**a**, **b**, …). For each one
   pick a machine and a counter. It can be **this** machine or **another** one — for a line
   total, pick the two packing machines.
5. **Formula.** Type it, or press one of the example buttons (`a - b`, `a + b`,
   `(a + b) * 12`, `a / 12`, `max(a, b)`). You can use `+ - * /`, brackets, numbers, and
   `max`, `min`, `abs`, `round`, `floor`, `ceil`.
6. **Try it.** Type example numbers for each letter (for example a = 500, b = 470) and press
   **Try**. You see the result (30). Nothing is saved yet.
7. **Add calculation**, then **Save**.
8. **Apply now.** This restarts the data collector for a few seconds so it starts using the
   calculation. No data is lost while it restarts.

!!! info "What changes and when"
    New results start **from the moment you press Apply now**. Past data is not changed.

## When the page says no

| Message | What it means | What to do |
|---|---|---|
| "… has no counter number yet" | That machine's counters were never confirmed | Confirm them in CS Admin (step **Confirm counts are real**) |
| "“c” isn't one of your values" | The formula uses a letter you did not add | Add value **c**, or fix the formula |
| "Someone else saved changes while you were editing" | Another person saved first | Reload the page and add yours again |
| Try shows "no result" | A value had no number | Fill every letter, then Try again |

## Calculation or Node-RED?

If the answer is a **number** for OEE and the dashboards, use a calculation. If it goes to
**another system or a person**, use [Node-RED](node-red-flows.md). A calculation is checked
and stored like a real counter; a Node-RED flow is more flexible but harder to check.
