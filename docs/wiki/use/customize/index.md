---
title: Customizing a client (Customize app)
layer: guide
owner_area: frontends
last_verified: 2026-09-29
---
# Customizing a client (Customize app)

> For the **automation team**. What the Customize app is for, which tool to use for which
> job, and what "saving" does. Up: [Start here](../../index.md)

## What Customize is for

Every factory is a little different. One line only counts what goes in and what comes out,
so scrap has to be calculated. Another line has two packing machines whose counts must be
added. Another client wants an alert when data is rejected. **Customize** is where you make
these changes for one client, without asking a programmer.

A client must be **set up in CS Admin first** (see
[Setting up a new client](../setting-up-a-client.md)). Customize works on top of that setup.

Open Customize from CS Admin (menu **Customization Hub ↗**). The link opens it on the same
client. The pages are:

| Page | What you do there |
|---|---|
| **Hub** | Summary of what this client has |
| **[Calculations](calculations.md)** | Make a new value from counters (**new**) |
| **[OEE settings](oee-settings.md)** | How OEE is calculated, per client and per line (**new**) |
| **[Node-RED flows](node-red-flows.md)** | Add Node-RED logic that runs on the factory box |
| **Integrations** | See the connections to other systems (read-only) |
| **PLC connections** | See the PLCs and whether they send data (read-only; each links to the CS Admin page where you change it) |

## Which one do I use?

| You want… | The result is… | Use |
|---|---|---|
| Scrap = what went in − good parts | a number that feeds OEE and history | **[Calculation](calculations.md)** |
| Line total = machine A + machine B | a number that feeds OEE and history | **[Calculation](calculations.md)** |
| Good parts = packs × 12 | a number that feeds OEE and history | **[Calculation](calculations.md)** |
| An e-mail/Teams message when something goes wrong | a message to a person | **[Node-RED](node-red-flows.md)** |
| Send production counts to the client's ERP or database | data for another system | **[Node-RED](connecting-other-systems.md)** |
| Try an idea on one box before making it permanent | an experiment | **[Node-RED](node-red-flows.md)** |
| Change how OEE decides a line was running, or treats counter jumps | a rule for the client or one line | **[OEE settings](oee-settings.md)** |

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
- **If someone else saved first**, the page tells you: "Someone else saved changes while you
  were editing". Reload the page and make your change again. Nothing is lost silently.
- **Saving is not applying.** Each page has its own button to start using what you saved:
  **Apply now** for Calculations and OEE settings, **Preview changes → Apply to box** for Node-RED.

## What is coming soon

These are **not available yet**. Do not promise them to a client as ready.

| Coming soon | What it will do |
|---|---|
| Node-RED helper beside the Python reader | Node-RED customizations on boxes that read PLCs with the Python reader, like Bispharma ([Connecting to other systems](connecting-other-systems.md)) |
| PLC on/off switch in CS Admin | Stop and start reading one PLC without the platform team |
