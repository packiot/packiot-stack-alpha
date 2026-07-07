# Incoplast (Copobras São Ludgero) — edge-flow migration assessment

- **Source**: `export_incoplast.json` review, 2026-07-08 (1,069 nodes,
  4 tabs, 3 subflows). SECRETS REDACTED here — the raw export contains
  cleartext credentials; see §Risks and DO NOT commit the export.
- **Why this doc**: first real-factory test of the ADR-0009/0010
  minimal-edge thesis; feeds Phase-F onboarding + client.yaml v1.x.

## Shape

| Tab | Nodes | Class |
|---|---|---|
| Client | 374 | standard pipeline + ERP integration + customizations |
| Operator UI v0.10.45 | 211 | LOCAL operator UI (ACTIVE; custom mui_* dashboard nodes) |
| Operator UI v0.10.42 / v0.10.40 | 345 | prior versions, disabled (dead sprawl) |
| SparkPlug subflows ×3 | 116 | one live (v1.10.37), two dormant |

~52% of the export is the thrice-versioned local operator UI.

## Local operator UI anatomy

Custom `mui_*` dashboard nodes + hand-written HTML templates INSIDE the
flow: login (Firebase Identity Toolkit direct), current-PO, PO
start/change/setup, downtime justification, scrap entry, shift hours —
reading Hasura (gqlpiot; a plain-http staging URL also left in) and
WRITING BACK to the PLC through the SparkPlug subflow (Send_Parameter,
change PO PackML, DBIRTH) via shared globals + 6 link pairs. UI and
pipeline are ONE program, not a separable frontend.

## What maps cleanly (transformer + client.yaml)

S7 reads (4 PLCs) · SparkPlug/PackML encode + counters · host health →
heartbeat · devices/ping · shifts from cloud DB · REST jobs/events sync
via integrations.http_poll.

## client.yaml v1.0 MISSING FIELDS

- plc.auth lacks S7 `rack`/`slot`.
- equipment_mapping has no home for ERP dimensions (recurso/etapa/empresa/custom field).
- No database/Oracle integration type (see G1).
- No field for operator auth (Firebase) or a local UI (by design — see G3).

## Gaps with NO architectural home (G1–G7)

- **G1 Bidirectional on-prem ERP/Oracle sync** (PACKIOT_PCPAPPARADA /
  packiot_pcpapproducao writes + PO/scrap/user reads from the customer
  Oracle). Biggest gap; needs a connector type + SQL templates + creds.
- **G2 exec/shell + local-file bridges** (oracle_get_pos.sh → txt/csv).
- **G3 On-box operator UI as first-class artifact** (offline-capable
  floor screens; no schema slot, no build/versioning story).
- **G4 Operator→PLC command path** (PO/parameter push via DBIRTH) —
  target is data-out oriented; operator-initiated PLC writes unmodeled.
- **G5 Edge self-management** (pm2 runtime, self-restart, weekly wipe).
- **G6 Local CSV persistence/offline buffering.**
- **G7 Edge-local operator auth** (Firebase at the edge).

## Operator-SPA replacement verdict

Functionally the standard operator+refdata+edge-api covers PO control,
justification, scrap, shifts, timeline. Blockers: (a) G4 — the SPA
needs an edge-api→edge command channel to push parameters to the PLC;
(b) offline-floor requirement (their UI is on-box deliberately);
(c) pt-BR + custom screens. A UX/offline decision, not a data-model one.

## Risks (redacted; full values in the raw export ONLY)

1. **Cleartext Oracle credentials for the customer ERP host — user and
   password are the same trivially-guessable word. ROTATE + move to
   secret storage. Highest severity.**
2. Tenant REST api_key + Firebase web API key hardcoded in flow URLs.
3. Plain-http staging GraphQL endpoint left in prod builders.
4. Egress = deprecated Google IoT Core + PubSub topic — whole wing
   replaced under 10.9 MQTT-direct.
5. pm2/non-container runtime, absolute /home/packiot paths, Oracle
   Instant Client 21_12 pin, private PLC IPs in config nodes.
6. Cross-client contamination (Montebello/MST fragments; enterprise
   name typo "INCOLPLAST" hardcoded).
