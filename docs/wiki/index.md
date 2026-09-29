---
title: Start here
layer: guide
owner_area: platform
last_verified: 2026-09-29
---
# Start here

> For the **automation team** and **Customer Success**. No programming knowledge needed.
> Engineers: the technical pages are under [For engineers](for-engineers.md).

## What Packiot does, in five sentences

1. A factory has **machines** grouped into **production lines**, and each machine has a
   small computer called a **PLC** that counts what goes in and what comes out.
2. A **factory box** (a small computer we install at the client) reads those counts from the
   PLCs every few seconds and sends them to the Packiot cloud.
3. The cloud turns the counts into **OEE**, one number that says how well the factory is
   running: **Availability × Performance × Quality**.
4. Plant managers see OEE and its details on dashboards, and operators on the factory floor
   use a tablet app to start production orders and say why a machine stopped.
5. Our team sets up each new client once, and then adjusts the numbers to fit how that
   factory works.

## OEE in one example

OEE answers: "Of the time we planned to produce, how much did we turn into good parts at full
speed?" It is three percentages multiplied together.

A line works one **8-hour shift** (480 minutes). Its rated speed is **100 parts per minute**.

| Factor | Question it answers | In this shift | Result |
|---|---|---|---|
| **Availability** | Was the line running? | Stopped for 60 min, so it ran 420 of 480 min | 420 ÷ 480 = **87.5 %** |
| **Performance** | When running, was it at full speed? | In 420 min at 100/min it could make 42,000. It made 37,800 | 37,800 ÷ 42,000 = **90 %** |
| **Quality** | Were the parts good? | Of 37,800 parts, 36,288 were good (1,512 scrap) | 36,288 ÷ 37,800 = **96 %** |
| **OEE** | All together | 0.875 × 0.90 × 0.96 | **75.6 %** |

Check: at full speed for the whole shift the line could make 48,000 good parts. It made
36,288. 36,288 ÷ 48,000 = 75.6 %. Same answer.

!!! tip "If a number looks too high"
    If Performance shows more than 100 %, the rated speed configured for that line is lower
    than what the line really does. Packiot shows the real number instead of hiding it at
    100 %, so you can fix the setting.

## Who uses which app

| App | Who uses it | What for |
|---|---|---|
| **front4** (the dashboards) | Client managers, and our team to check a client | OEE by line, shift, day; downtimes; production; reports |
| **Operator app** | Machine operators, on a tablet next to the line | Start and finish production orders, give the reason for each stop |
| **CS Admin** | Customer Success | Set up a new client: factory structure, shifts, PLC connections, the factory box, go live. See [Setting up a new client](guide/setting-up-a-client.md) |
| **Customize** | The automation team | Adjust a client that is already set up: calculations, Node-RED flows, OEE settings. See [Customizing a client](guide/customize/index.md) |

There is also a **barcode app** for factories that scan the boxes they pack.

## Where to go next

| I want to… | Read |
|---|---|
| Set up a new client from zero | [Setting up a new client](guide/setting-up-a-client.md) |
| Make a new value from counters (scrap, line totals) | [Calculations](guide/customize/calculations.md) |
| Add logic on the factory box (alerts, extra processing) | [Node-RED flows](guide/customize/node-red-flows.md) |
| Send production data to an ERP, a database or another system | [Connecting to an ERP / other systems](guide/customize/connecting-other-systems.md) |
| Understand a word | [Glossary](glossary.md) |
| See how the system is built | [For engineers](for-engineers.md) |
