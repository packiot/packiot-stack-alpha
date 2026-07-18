# ADR-0026 Wave-2/3 — back4-api consumer evidence (inventory × access logs)

- **Date:** 2026-07-18
- **Program:** ADR-0026 API-layer consolidation (task #54), strangler-fig retirement.
- **Companion:** `primary-api-dedup-map-2026-07-17.md` (Wave-1, done); `back4-api-endpoint-inventory.csv` (this wave's join key).
- **Method:** two read-only lenses joined — (A) endpoint **inventory** (what each route is + its edge-api/refdata target), (B) prod ALB access-log **evidence** (who actually calls it). No prod changes, no AWS resources created.

## Headline verdict

**Nothing in back4-api is safe to retire yet — the evidence window is too short, not the endpoints too active.** Access-logging was enabled ~1 day ago (2026-07-17 12:45Z → 2026-07-18 14:20Z ≈ **25.6h**). That window clears only *continuous/sub-daily* consumers; it cannot distinguish "retired" from "daily/weekly/monthly batch that hasn't fired." The join gives us a firm **KEEP** list (confirmed-active) and a **WATCH** list (quiet-but-inconclusive) — but zero **RETIRE-NOW**.

**Most consequential finding:** `GET /api/v1/neopac/sap-report-sync` is **ACTIVE** (332 hits, UA `integration-packiot`) — a Wave-3 **external SAP contract is live**, not dormant. This is the proof of the rule: *external-contract endpoints can never be retired on log silence*, because a sibling monthly SAP endpoint would look identical to "dead" in a 25.6h window.

## Evidence provenance

| ALB | Region | Log bucket + prefix |
|---|---|---|
| edge-api (`edge.api4.packiot.com`) | us-east-1 | `packiot-alb-logs-us-east-1/edge-api/AWSLogs/639178078294/elasticloadbalancing/us-east-1/` |
| back4-api (`api4.packiot.com`) | us-east-2 | `packiot-alb-logs-us-east-2/back4-api/AWSLogs/639178078294/elasticloadbalancing/us-east-2/` |

616 objects/bucket, 5-min flush, 0 gaps, 0 unparseable. Public internet sprays both ALBs with vuln-scanners (`/.env`, `wp-content`, phpunit) — **all WAF-403/400, never 2xx** — so signal = endpoints with ≥1 success: **edge-api 17** (78.5% of reqs), **back4-api 12** (94.2%). Staging-host nginx (10-day window) fronts only Grafana+Authentik SSO, **zero API traffic** — ruled out; the two prod ALBs are the sole authoritative source.

## The join — KEEP / WATCH / SHIM

### KEEP — confirmed-active (2xx in window; do NOT retire)

**edge-api** (already the target tier — "keep" = correct by construction): `POST /api/downtimes` (2537, node-red), `…/justify` (342), `…/split`, `…/create-manual-event`, `…/edit-manual-event`, `…/split-manual-downtime`; `POST /api/production-orders/setup` (45, node-red), `…/create`, `…/replace`, `…/start`, `…/change-time`; `GET /` (health/browsers).

**back4-api** (active → each needs a fate before back4 can die):

| endpoint | reqs | class | disposition |
|---|---|---|---|
| `POST /devices/ping` | 10,445 | NET-NEW (device) | rebuild in obs/ingestion plane |
| `GET /Integration/job_report/:id` | 2,306 | **EXTERNAL** (Incoplast) | shape-preserving shim + coordinate |
| `GET /events_incoplast` | 1,693 | **EXTERNAL** (Incoplast) | shim + coordinate |
| `GET /jobs_incoplast` | 154 | **EXTERNAL** (Incoplast) | shim + coordinate |
| `POST /devices/infra-events/plcs` | 768 | NET-NEW (device write) | ingestion plane |
| `GET /api/v1/neopac/sap-report-sync` | 332 | **EXTERNAL** (NEOPAC SAP) | **active SAP contract** — shim + owner sign-off |
| `POST /getEmbedToken` | 86 | **EXTERNAL** (PowerBI) | shim (MS service principal) |
| `POST /refreshDataset` | 46 | **EXTERNAL** (PowerBI) | shim |
| `POST /api/production-orders/insert` | 1 | NET-NEW (PO CSV import) | ⚠️ this is the **#52/#60 unauthenticated bulk-write controller — and it has live traffic** |

### WATCH — quiet-so-far (no 2xx in window; inconclusive → 40-day clock)

Every inventory endpoint *not* in the KEEP list. Notably the **11 DUP-OF-EDGE-API admin CRUD** routes (`/api/admin/users|user-roles|pages` GET/POST/PUT/DELETE) showed **zero hits**. That is *consistent with* CS-Admin already using edge-api for these (the Wave-1 direction) — but 25.6h can't even clear a daily batch, so this is **suggestive, not conclusive**. These are the cleanest Wave-2 retirement candidates *if they stay quiet across the full watch window*.

### SHIM-GATED (Wave-3) — retirement blocked on shims + external coordination, regardless of logs

The 12 external-contract endpoints (`back4-api-endpoint-inventory.csv`, class=EXTERNAL). Frozen response envelopes (`{data}`, `{page,results,data}`, specific view columns) → shims must be shape-preserving and verified per external consumer. **Log silence is never sufficient here.**

## Watch plan (evidence accumulation)

| Cadence to clear | Min window | Cleared today (25.6h)? |
|---|---|---|
| continuous / hourly | hours | ✅ |
| daily batch | ≥3 days | ❌ |
| weekly batch | ≥3 weeks | ❌ |
| monthly / month-end | **≥40 days** (must cross a calendar month-end + margin) | ❌ |
| quarterly+ / external SAP | log-silence **never** sufficient → owner/contract sign-off | ❌ |

**Rule:** promote a WATCH endpoint to RETIRE-NOW only after the **≥40-day cross-month observation**; gate any EXTERNAL/SAP retirement on explicit owner sign-off irrespective of silence. Keep ALB access-logging enabled; re-run the parse at **T+7d, T+30d, T+40d** (2026-07-25 / 08-17 / 08-27).

## Reproducible re-mine (Athena, read-only over the log buckets)

The exact DDL + histogram query is `athena_ddl.sql` (parser `parse.py`/`classify.py` were the one-off local path given the ~6 MB volume). Athena table reads the existing buckets only; point query-results at a scratch prefix you own. Core query — normalized path (strip query string, collapse `/[0-9]+`→`/:id`, UUID→`/:uuid`), grouped with per-status-code + distinct-IP/UA + last-seen. Add the day-partitions for each new date before re-running.

## Cross-references / follow-ups

- **#52 / #60** — the PO CSV importer (`ProductionOrdersController.js`, own `pg.Pool`, 3/4 routes outside the `/api/admin/*` guard; `routes.js:48` un-slashed `/api/admindowntime-reasons/upload` = auth-bypass typo) is **live-trafficked** (`/api/production-orders/insert` hit in-window) — not dormant code. Elevates the security urgency while back4-api still runs.
- **Observability-plane device/PLC endpoints (10)** — `/devices*`, `/infra-events/plc*` are a different domain than product reads; confirm the new stack's infra-events home before assigning a target (they look like edge-node-red/oeecloud telemetry sinks), don't force into refdata just because they're GETs.
- **NO-LOG-COVERAGE** — retired primary-api paths, Hasura/GraphQL, internal-only routes are not fronted by these ALBs; they need a different evidence source (Hasura logs / VPC flow).
