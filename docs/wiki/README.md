# Packiot Stack Wiki

The engineering + operations reference for the Packiot industrial-IoT / OEE platform.
Every page is **sourced from the live code** (real `file:line` citations) — where a
claim is a proposal or differs between branches, it's flagged rather than smoothed over.

> New here? Read **[Platform Overview](01-platform-overview.md)** first, then
> **[Onboarding a Client](02-onboarding.md)** for the hands-on flow.

## Contents

| # | Page | What's in it |
|---|------|--------------|
| 01 | [Platform Overview](01-platform-overview.md) | What Packiot is, the end-to-end data flow, the control-plane vs data-plane split, the two DB planes (`packiot` legacy vs `packiot_analytics` live) |
| 02 | [Onboarding a Client](02-onboarding.md) | The CS-Admin onboarding process step by step: hierarchy build order → the compose-from-hierarchy wizard → generate → capture → cutover |
| 03 | [CS-Admin Forms Reference](03-csadmin-forms.md) | Every onboarding form, field by field: required vs optional, the DB column it maps to, and the gotchas (phantom `code`, week-encoding, `status_type`) |
| 04 | [Edge & Data Ingestion](04-edge-and-ingestion.md) | PLC → Node-RED/reader → sparkplug-agent → SparkPlug B/mTLS → cloud decode. The config-as-data descriptor model, edge deployment, count-index |
| 05 | [Cloud Services & OEE Compute](05-cloud-services-and-oee.md) | edge-api (control plane), refdata-api (reads), oeecloud-worker / stream-engine (OEE math), RabbitMQ, auth posture |
| 06 | [Database & Data Model](06-database.md) | The schema: hierarchy, packml_register, the OEE aggregate cascade, shifts (seconds-from-week-start), the dual plane |
| 07 | [Frontends, Infra & Auth](07-frontends-infra-auth.md) | front4 / operator / csadmin, the deploy pipeline, AWS infra, Cognito + oauth2-proxy + CloudFront |
| 08 | [Concepts & Glossary](08-concepts.md) | count_index, tp_equipment, OEE = A×P×Q, PackML params, week-encoding, the descriptor — the vocabulary |

## The 30-second mental model

```
PLC ─(SparkPlug B / mTLS)─▶ edge (agent) ─▶ cloud decode (edge-transformer)
                                                   │ RabbitMQ
                                                   ▼
                              oeecloud-worker  ──▶  PostgreSQL + TimescaleDB
                              (writes raw + computes OEE)      │
   edge-api (control/writes) ◀── CS-Admin / operator          │ reads
   refdata-api (reads)       ─────────────────────────▶ front4 / operator SPA
```

- **Config in** flows through **edge-api** (NestJS control plane): CS-Admin builds the
  enterprise→site→area→line→machine hierarchy + `packml_register` topic routes.
- **Telemetry in** flows PLC → SparkPlug B → cloud, is decoded by **edge-transformer**,
  and written + turned into OEE by **oeecloud-worker** (the OEE math lives in the Go
  worker, **not** the database anymore — TimescaleDB only stores + aggregates).
- **Numbers out** are served by **refdata-api** to the **front4** product and the
  **operator** kiosk.

## Conventions in this wiki

- **Shipped vs proposed** is always distinguished. E.g. edge "Box Ops" deploy is
  GitHub `workflow_dispatch` today; the AWS-SSM Box Ops substrate is ADR-0049
  design-of-record. The live auth gate is oauth2-proxy+Cognito (Authentik retired).
- **Branch drift** is called out: some infra (CloudFront/WAF, the rich edge topology)
  is authoritative on `origin/staging` / `origin/production`, not every feature branch.
- Citations point at `packiot-stack-alpha/…` unless noted (edge-api, services,
  terraform, docs/adr are the main trees).

---
*Maintained alongside the code. When you change a contract, change the page.*
