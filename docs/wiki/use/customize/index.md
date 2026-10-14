---
title: Customizing a client (Customize app)
layer: guide
owner_area: frontends
last_verified: 2026-10-13
---
# Customizing a client (Customize app)

> For the **automation team**. What the Customize app is for, which tool to use for which
> job, and what "saving" does. Up: [Use Packiot — start here](../index.md)

## What Customize is for

Every factory is a little different. One line only counts what goes in and what comes out,
so scrap has to be calculated. Another line has two packing machines whose counts must be
added. Another client wants an alert when data is rejected. **Customize** is where you make
these changes for one client, without asking a programmer.

A client must be **set up in CS Admin first** (see
[Setting up a new client](../setting-up-a-client.md)). Customize works on top of that setup.

Open Customize from CS Admin (menu **Customization Hub ↗**). The link opens it on the same
client. The client's name is shown at the top; **Switch** picks another client. The menu on
the left has these pages:

| Page | What you do there |
|---|---|
| **Hub** | Summary of what this client has, and the calculations it uses today |
| **[Calculations](calculations.md)** | Make a new value from counters |
| **[OEE settings](oee-settings.md)** | How OEE is measured, for all lines and for single lines |
| **[Node-RED flows](node-red-flows.md)** | Add Node-RED logic that runs on the factory box |
| **Integrations** | See the connections to other systems (read-only) |
| **PLC connections** | See the factory box and whether each PLC sends data (read-only; you change them in CS Admin) |

If a page says the client "isn't set up yet", finish
[Setting up a new client](../setting-up-a-client.md) in CS Admin first.

## Which one do I use?

| You want… | The result is… | Use |
|---|---|---|
| Scrap = what went in − good parts | a number that feeds OEE and history | **[Calculation](calculations.md)** |
| Line total = machine A + machine B | a number that feeds OEE and history | **[Calculation](calculations.md)** |
| Good parts = packs × 12 | a number that feeds OEE and history | **[Calculation](calculations.md)** |
| An e-mail/Teams message when something goes wrong | a message to a person | **[Node-RED](node-red-flows.md)** |
| Send production counts to the client's ERP or database | data for another system | **[Node-RED](connecting-other-systems.md)** |
| Try an idea on one box before making it permanent | an experiment | **[Node-RED](node-red-flows.md)** |
| Change how OEE decides a line was running | a rule for the client or one line | **[OEE settings](oee-settings.md)** |

**Rule of thumb:** if the answer is a **number** that should appear in OEE and on the
dashboards, use a **Calculation**. If the answer goes **somewhere else** (another system, a
person, an experiment), use **Node-RED**.

Why prefer a Calculation when both could work? A Calculation is checked, tried with example
numbers and stored like a real counter, so every report uses it the same way. A Node-RED
flow is more flexible, but it runs only on that one box and is harder to check.

## Saving is safe

- **Saving never changes the client's setup status.** A client that is live stays live. You
  cannot "undo" an onboarding by saving a calculation or a setting.
- **Saving only touches what that page owns.** Saving a calculation does not overwrite a
  Node-RED flow or an OEE setting that someone else saved a minute ago.
- **If someone else saved first**, your save is refused and the page tells you, for example
  "Someone else saved changes while you were editing". This happens if anyone saved **any**
  Customize page for this client after you opened yours. Reload the page and make your change
  again. Nothing is overwritten silently.
- **Saving is not applying.** Each page has its own button to start using what you saved:
  **Apply now** for Calculations and OEE settings (it restarts a Packiot program in the cloud
  for a few seconds; no data is lost), **Preview changes → Apply to box** for Node-RED. Apply
  now is greyed out while you have unsaved changes.
- **On a test client** (a sandbox copy), Apply now says "Test client — nothing was
  restarted".

## Related switches in CS Admin

Two things that look like customizations are set in CS Admin, not here:

| You want… | Where |
|---|---|
| Stop or start reading one PLC | CS Admin → **Onboarding** → **Connect the PLCs**: the **Reading / Off** switch on that PLC, then **Install on the factory box** |
| Leave days out of OEE because a line is not in use on purpose | CS Admin → **Factory → Lines** → the line's settings → **Out of service** |
