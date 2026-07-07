# 7 — Customizations and Real Factories

Everything up to here described a clean architecture. This chapter is where it meets
a real factory — and a real factory is never clean. It is the most honest chapter in
the guide, because it is about the parts of the problem the architecture does *not*
yet solve, and how we turned those gaps into a plan rather than a surprise.

## Why customization is unavoidable

No two factories are identical. One reads its PLCs over Siemens S7, another over
OPC-UA. One needs to write downtime events back into the customer's on-premises ERP.
One prints reel-traceability labels. One computes a bespoke scrap category from a
machine signal no other customer has. If the platform tried to express all of this
in configuration, the configuration would become a programming language; if it
forced all of it into compiled Go, every one-off would need an engineer and a
release.

So the architecture deliberately keeps a **customization surface** at the edge —
the Node-RED layer from [Chapter 3](03-the-edge.md) — and the governing question
becomes: *what belongs in config, what belongs in a governed Node-RED customization
flow, and what belongs in the standard compiled pipeline?*
[ADR-0009](../adr/0009-edge-transformer-go-service-and-nodered-split.md) draws that
line. The rest of this chapter tests the line against a factory that pushed on every
part of it.

## A real factory: Incoplast

Incoplast is a plastic-film plant. Its edge Node-RED export is **1,069 nodes** — and
studying it taught us more about the real shape of the problem than any amount of
architecture diagramming. Three findings mattered.

### Finding 1 — half the "edge flow" is a frontend

The single biggest surprise: **about 52% of the export is an operator UI** — and it
was shipped *three times*, three versions kept side by side, only one enabled. This
is not the platform's operator SPA; it is a bespoke on-screen application built out
of custom Material-UI Node-RED nodes, with the login page, the production-order
screens, and the CSS all serialized as node properties *inside the flow*. A whole
React-style app wearing a Node-RED costume, running on the factory floor.

Why on the floor and not in the cloud? Almost certainly because the floor cannot
assume reliable internet — so the operator's screen had to live on the local box.
That single requirement — **offline-capable floor operation** — turns out to explain
a lot of what looks like eccentricity in a real factory's edge.

### Finding 2 — the UI is welded to the machine

A normal frontend reads data and displays it. Incoplast's operator UI *writes back
down to the PLC*: starting a production order or changing a parameter from the screen
pushes the change through the SparkPlug pipeline to the controller. The UI and the
ingestion pipeline share globals and are, functionally, **one program**. You cannot
lift the screen out cleanly — it has its hands on the machine-control path.

### Finding 3 — deep ERP coupling

The flow performs a two-way sync with the customer's on-premises Oracle ERP: writing
downtime and production records into ERP tables, reading production orders, scrap,
and the user list back out. Some of it goes through a database connector; some
through shell scripts writing CSV files. None of it has any representation in the
platform's configuration model.

(It also contained cleartext database credentials — a reminder, recorded prominently
in the assessment, that exported flow files are secret-bearing artifacts and must be
treated as such.)

## From findings to requirements

The instinct on seeing all this is to call it "the messy customer" and move on. The
discipline is to treat every intricacy as a **requirement**: each one must either be
*ported* into the stack or become an *explicitly designed-for* capability, before a
factory of this class can migrate.
[ADR-0019](../adr/0019-edge-customization-capabilities.md) does exactly that, and the
mapping has a satisfying property — several gaps are already solved by work described
in earlier chapters:

| Intricacy | Where it lands |
|-----------|----------------|
| On-box operator UI | **The platform's own operator SPA, deployed at the edge.** Because the SPA became a static container whose backends are just proxy targets ([Chapter 6](06-apis-and-operator.md)), pointing it at a *factory-local* edge-api gives an offline-capable floor screen — no bespoke in-flow UI needed. |
| Edge-local operator login | **edge-api's `/session`** — already runs factory-local on a real credential store. |
| Custom calculations, label logic, reel tracking | **Governed Node-RED customization flows** — legitimately stays here per ADR-0009, once refactored to pass the governance rules. |
| Bidirectional ERP / database sync | **A new `client.yaml` integration type** — the biggest genuine gap; needs a connector with SQL templates and, above all, secrets by *reference*, never inline. |
| **Operator → PLC command path** | **A new edge command channel** — the one component the stack genuinely lacks. edge-api publishes a typed command to a local broker topic; the transformer (which owns the PLC session) executes the write. |

That last row is the important one. The whole architecture is *data-out* oriented —
machine to cloud. Incoplast revealed that a real operator screen also needs to send
commands *in* — cloud to machine. That capability is now a named, designed-for
requirement with a home, and a hard prerequisite before any Incoplast-class factory
(one with a local UI or PLC write-back) cuts over. Factories *without* those needs
are unaffected and can migrate on the simpler path.

## The lesson

The reason this chapter exists — and the reason we spent real effort dissecting one
customer's 1,069-node flow — is that **the gaps a clean architecture doesn't cover
are exactly the ones that sink a migration if you find them mid-rollout.** Finding
them by reading a real factory's flow, turning them into a written requirements list,
and discovering that most already have homes, is the difference between a rollout
that goes to plan and one that surprises you in production.

---

Next: [Observability](08-observability.md) — how you know all of this is working.
