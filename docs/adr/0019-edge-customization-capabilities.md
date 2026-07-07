# ADR-0019 — Edge customization capabilities: every Incoplast-class intricacy gets a home

- **Status**: Proposed (2026-07-08) — decider: Emmanuel Podestá.
- **Context**: the Incoplast assessment (`docs/clients/
  incoplast-migration-assessment.md`) is the first real-factory test of
  the minimal-edge thesis and surfaced 7 capability gaps (G1–G7).
  **Owner directive (2026-07-08): these are REQUIREMENTS — each must be
  ported into the stack or become an explicitly designed-for
  capability.** No factory of this class can cut over (Phase F) before
  its gaps have homes.

## Decision — gap-by-gap homes

| Gap | Home | Mechanism |
|---|---|---|
| **G1 on-prem ERP/DB sync** (bidirectional Oracle) | client.yaml `integrations.database` + **Node-RED customization flow (transitional)** | New integration type: driver (oracle/odbc/mssql), secret REF (never inline — the Incoplast export's cleartext creds are the cautionary tale), SQL templates for read (POs/scrap/users) + write (downtime/production), cadence, dedup key (their `differences` nodes become declarative). Transitional: stays a governed customization flow with secrets externalized; deep port to a Go connector only on demand. |
| **G2 exec/file bridges** | **REJECTED as a standard capability** | Shell-outs + CSV handoffs are the un-observable failure mode the stack exists to kill. Existing bridges get migrated INTO G1's connector; a governed `customization_flows[]` escape hatch remains for genuine one-offs, CI-linted, no silent files. |
| **G3 on-box operator UI** | **Our operator SPA, deployed at the edge** | The wave-3/4 rebuild made this possible: the SPA is a static nginx container whose backends are path-proxied — point `/api/*` + `/session` at the FACTORY-LOCAL edge-api and `/v1/*` at a local refdata (or cached reads). Offline-first floor UI = same artifact, different proxy targets. Kills the 556-node in-flow UI class. pt-BR = language_packs (already dynamic). |
| **G4 operator→PLC command path** | **New: edge command channel** | The one genuinely missing component. Design: edge-api (factory-local) publishes typed commands (PO setup/parameter write) to a local broker topic (`edge.commands.<tenant>`); edge-transformer subscribes and executes the PLC write (DBIRTH/DDATA/S7) — the transformer already owns the PLC session. Commands are audited via user_logs like every operator action. Small, well-bounded Go work; prerequisite for G3 full parity. |
| **G5 edge self-management** | Containerized edge stack | pm2/self-restart/context-wipes dissolve into the factory docker compose (restart policies, healthchecks, image updates) — already the 10.9 direction; this ADR just states it as the requirement. |
| **G6 local persistence / offline buffer** | edge-transformer outbox (exists) + G1 dedup | ADR-0011's SQLite outbox is the durable buffer; CSV logging replaced by the transformer's structured logs + heartbeat. Local exports for humans, if truly needed, are a customization flow. |
| **G7 edge-local operator auth** | **edge-api /session (exists — ADR-0018 wave 2)** | bcrypt-on-users login already runs factory-local with edge-api; Firebase-at-the-edge is retired for floor operators. CS-Admin manages credentials (operator-password endpoint). |

## client.yaml v1.1 additions this implies

`plc.endpoints[].rack/slot` (S7) · `equipment_mapping[].erp` (recurso/
etapa/empresa/custom dims) · `integrations[].type: database` (per G1)
· `operator: {mode: edge|cloud, language}` (per G3) · `commands:
{enabled, allowed[]}` (per G4). Schema stays secrets-by-reference.

## Consequences

- Positive: the Incoplast class (local UI + ERP coupling + offline
  floor) becomes onboardable with config + one governed flow, not a
  1,069-node fork; G3/G7 reuse this week's operator work verbatim.
- Negative: G4 is new engineering (bounded); G1 governance must be
  enforced or it re-becomes sprawl; edge deployments grow two
  containers (operator, maybe refdata-cache).
- Sequencing: G4 + client.yaml v1.1 land before the FIRST
  Incoplast-class Phase-F cutover; CPACK-class factories (no local UI,
  no ERP) are unaffected and can cut over on v1.0.

## References

Incoplast assessment (gaps + risks) · ADR-0009 (customization-stays-
in-Node-RED rationale this refines) · ADR-0010/0011 (transformer/
outbox) · ADR-0018 (the operator architecture G3/G7 reuse) ·
overview/07 Phase F.
