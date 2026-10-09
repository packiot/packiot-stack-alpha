# ADR-0047 reference — "PackML" here is our internal edge wire-contract, not an OMAC compliance standard

**Date:** 2026-08-26. **Status:** clarifying note (pairs with the counterroles-removal note).

## Context / evidence
A protocol audit (2026-08-26) established two facts about how PackML is actually used in this stack:

1. **No client is PackML-native.** Every factory is read via raw **S7 / Modbus / (proprietary B&R) OPC-UA** registers that our reader/Node-RED *synthesizes* into a PackML-shaped SparkPlug topic tree. Bispharma (16 S7) and Bisnago (19 S7) are bare DINT totalizers with **zero** PackML content at the PLC; CPACK borrows PackTag *names* over B&R's proprietary OPC-UA but is hand-mapped, not the OPC-UA PackML companion-spec. **The OMAC/PackML interoperability promise is realized for zero clients.**
2. **No compliance requirement.** No contract, datasheet, or certification anywhere requires PackML/OMAC/ISO-TR-22400. It appears only as internal engineering vocabulary.

## Decision / framing
Treat the internal "PackML" model — the `Parameter30700..30899` IDs, `packml_register`, and the count-index addressing — as **our canonical edge wire-contract and internal metric namespace**, NOT as an OMAC PackML compliance implementation.

- The **value** it delivers is real but internal: a consistent metric namespace and the OEE contract keyed off it.
- Because the interoperability benefit is not exercised, do **not** over-invest in "PackML-correct" addressing. Keep the shape (so a genuinely PackML-native client could plug in later) but don't treat the standard as a constraint.

## Coupling reality (why we did NOT rip PackML out — "Option A")
The downstream is **already `id_equipment`-native**: all OEE/runtime DB functions, the worker, and `equipment_values` reference zero PackML numbers / count-indices. The genuine PackML-number coupling is quarantined at the edge (the decoder's `calc_production_counters` + the retired oeecloud-node-red). That is a healthy anti-corruption boundary that already exists.

**So Option A = formalize that boundary, do not relitigate the wire protocol:**
- Honest-semantics comments on the LIVE `packml_register.id_{infeed,outfeed}counter` columns (they hold wire count-indices, not id_equipment) — see `db/schema/packml-count-index-column-comments.sql`. This prevents the counterroles-collision class from recurring.
- GC the genuinely-dead remnants (`packml_register.id_rejectcounter`, `areas.id_*counter`).
- Do **not** drop the live count-index columns (Phase-9 reads them) and do **not** rename `id_unit → id_equipment` (distinct nullable machine-vs-line marker).
