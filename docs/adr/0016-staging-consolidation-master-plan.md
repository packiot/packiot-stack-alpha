# ADR-0016 — Staging consolidation to ONE flow: the master plan

- **Status**: PROPOSED (2026-07-03)
- **Goal**: one execution flow — the refactored stack (Go services,
  pool multi-tenancy, CAggs, zero PL/pgSQL compute, no Hasura,
  query-api reads) — at **100% behavioral parity with prod client-side
  at every consumer surface**, minus a consumer-verified bloat ledger.
- **Evidence base**: prod write census + oeecloud-node-red flow grep +
  column-population profiles + RMQ content audit (session 76 round 17,
  all SELECT-only).

## 0. Parity, defined honestly

"100% parity" = identical behavior AT CONSUMER SURFACES, not identical
bytes everywhere:
1. PowerBI gate objects (37 + `production_data_sync_enterprise_06` —
   discovered active, added): 5-dimension gate per object.
2. Operator UI + edge-api flows (write paths + audit).
3. Reference-read contract (refdata/query-api; Hasura until retired).
4. UNS + customer sync consumers (must be ENUMERATED first — Phase I).
5. Written data streams: column-population profiles must match prod's
   (the analogs lesson: 614/h on prod, dropped by staging today).

Anything NOT consumed goes to the **bloat ledger** (§7) — removal with
evidence, never silent omission. A divergence without a consumer check
is a parity violation; with one, it's an optimization.

## 1. ADR-0010 — finish the ingest surface (the biggest gap)

Prod's pipeline writes ~10 targets incl. UPDATE paths; the Go worker
does 2, insert-only. Ports, each with prod-read fidelity + live bake:

| # | Port | Prod evidence | Notes |
|---|---|---|---|
| 10.1 | analogs metric kind → equipment_values.analogs | 614 rows/h | small; classifier + writer column |
| 10.2 | EV UPDATE paths (CPAC 5-min smoothing, operator writeback) | 10 UPDATE nodes | read flows for exact semantics FIRST |
| 10.3 | PLC PO control (30800-899) → production_orders lifecycle | 8k ins/day | the big one; reuses natural-key lessons |
| 10.4 | direct equipment_events (line downtimes, lead machine 30702) | 4+2 nodes | pairs with 14.3 deriver |
| 10.5 | uns_metrics writer | 7.8M rows | home decision in §5 first |
| 10.6 | box scans → equipment_boxes_cust_13 + scanned_boxes | 486k ins | customer-13 stream |
| 10.7 | packml_register writeback + packml_tx_states | 4+2 nodes | config plane |
| 10.8 | pipeline user_logs entries | 8 nodes | with §5 user_logs home |
| 10.9 | MQTT cutover: simulator → MQTT; edge-transformer = THE ingest; retire nodered wrap + direct-AMQP publish | — | LAST; kills the dual-emit residual |

Rule per port: capture prod flow nodes verbatim → port → prod-read
fidelity (speed33 method) → bake vs Flow 1 → retire the nodered node
in the SAME change (bug-241 rule).

## 2. ADR-0014 — finish the compute extraction

- **P2 close-out (Jul 9)**: ready-SQL committed; ONE bake at a time.
- **P3a events deriver**: substrate live (both flows); gaps-and-islands
  SQL (no gapfill PL/pgSQL); config-extract prod's exclusion lists;
  bake vs F1's derived events. NOTE 10.4 writes SOME events directly —
  deriver + direct writes must partition cleanly (prod's own split).
- **P3b runtime rollups**: equipment/area/site × grains + shift
  variants. Strategy: hierarchical CAggs where windows are pure time
  buckets; Go jobs where PO/shift-window logic intrudes
  (`piot_create_or_adjust_po_runtmites` 12KB → Go). 678M updates/cycle
  on prod says: design for UPSERT churn, verify with row-profile bakes.
- **P3c UNS current family (7+ tables)**: CONSUMER CHECK FIRST — if
  only nodered UNS flows read them, they may collapse into query-api
  computed reads (bloat ledger candidate); if front4/customers read
  them, port as Go refreshers.
- **P4 customer ports**: speed33 ✅, shift06 ✅(c-gen); remaining:
  sap_13 (back4-api coordination — START NOW, longest lead),
  production_data_sync_enterprise_06 (capture + port — NEW),
  boxes_cust_13, piot4_13_* ×4 (incl. 46KB production_po),
  client6 label fns, and the get_report_* deep computes (23-27KB) —
  whose RETURNS TABLE(...) rewrite is what unlocks Wave 3 flip #2.
- **P5**: DROP piot_* namespace at contract time.

## 3. ADR-0012 — finish the schema waves

- Wave 2: sap_13 + sync_06 (above). Wave 3: flips as rowtype
  dependencies clear; 23 view re-points at promotion. Wave 4 contract:
  §7 ledger. Phase 5 (prod) stays gated (elevated access + sign-offs +
  month-boundary bake).

## 4. ADR-0015 — mature the read side

- Catalog v2 once P3b lands: OEE/availability/performance/quality
  metrics (need runtime data), shift dimension joins, saved views.
- front4/operator adopt query-api (P2 widgets) — internal bake.
- Flow-route to the consolidated DB at §6 flip. GraphQL stays
  conditional.

## 5. Homes for the unhomed (decisions needed, Phase I)

| Item | Options | Lean |
|---|---|---|
| user_logs | (a) edge-api writes consolidated DB directly; (b) dual-write window | (a) at flip — audit MUST be atomic with writes |
| uns_metrics | port writer (10.5) vs derive-on-read | consumer check decides |
| mirror_id_map etc. | follows mirror-worker (which RETIRES at consolidation — staging stops mirroring prod? NO: staging still needs prod data → mirror-worker stays, pointed at the ONE DB) | keep, repoint |
| historical data | one-shot copy F1 history (EV 8.2M, events 281k, POs 18k, user_logs 120k) into consolidated DB before flip | yes — staging keeps its past |

## 6. The consolidation flip (endgame)

1. Freeze feature work; full-surface side-by-side comparator (the
   3-flow machinery's final job): every consumer surface diffed for
   7 days.
2. Flip = env/connection change: edge-api, workers' source_type=""
   route, mirror-worker target, query-api DB. (Promote packiot_shadow
   OR rename — decide by ops simplicity; rename keeps DSNs.)
3. RETIREMENT LIST (the payoff): shadow_go_port schema, shadow-mirror
   service, dual-emit flag + SHADOW_* envs, fan-out (→ plain write),
   hasura + hasura-init containers, edge-nodered GraphQL tab,
   oeecloud-node-red pair (after 10.x complete), piot_* engine
   (after P3/P4), F2 dashboards/panels.
4. Rollback: old DB kept frozen-read for 30 days; flip is env-reversible.

## 7. The bloat ledger (deliberate, consumer-verified divergences)

Already decided: retention (raw 180d, agg 90d — vs prod's unbounded +
496M invalidation backlog) · skipped 1s/ohlc/boxes CAgg families
EXCEPT ca_discrete_changes_1s (load-bearing — adopted) · _past/_archive
hypertable generations · monitoramento_* (602k staging / 28M prod,
zero reads) · Hasura (14+5 alpha → 0 at flip) · version sprawl
(3 shift-compute generations [2 broken on prod!], mirror_reason ×3,
feed_agg ×4, uns refresh ×3, _test/_temp) · hot/warm matview pairs
(consumer check pending) · staging cadences where prod cron unreadable
(output-equivalence baked instead).
Pending consumer checks: UNS current family, hot/warm matviews,
uns_metrics, analogs consumers (WHO reads them — before porting 10.1
semantics beyond storage).

## 8. Phasing + dependencies

- **Phase I (now)**: consumer-enumeration sweep (UNS, matviews,
  analogs, boxes, uns_metrics — pg_stat + repo greps + query-log
  method); primary-api/back4/reports WRITE census (untested blindspot);
  sap_13 + c35 human coordination START; homes decisions (§5);
  sync_06 capture.
- **Phase II (Jul 9+)**: P2 close-out → events deriver bake → 10.3 PO
  control bake (one bake at a time).
- **Phase III**: P3b rollups; P3c per consumer evidence; 10.1/10.2/
  10.5/10.6 ports.
- **Phase IV**: remaining P4 customer ports + deep-compute rewrites +
  Wave 3 flips; 10.9 MQTT cutover.
- **Phase V**: §6 flip + retirements + Wave 4 contract.
- **Phase VI**: ADR-0012 Phase 5 (prod) planning with everything baked.

## 9. Self-critique — does this reach 100%?

- YES at consumer surfaces, IF: (a) the Phase I consumer enumeration is
  exhaustive (method: the Hasura query-log lesson — observe, don't
  assume); (b) every port passes call-time prod fidelity (the
  dead-generation lesson); (c) the §6 side-by-side bake covers ALL
  surfaces incl. month-boundary; (d) the §5 homes land before flip.
- Residual risks, mitigations: prod cron cadence unreadable → output-
  equivalence bakes + elevated read at Phase VI; PubSub payload types
  beyond repo evidence → prod column profiles are the backstop;
  writers outside oeecloud (primary-api/back4/reports) → Phase I
  census is MANDATORY before declaring the write surface complete;
  one-bake-at-a-time serializes the timeline — accepted cost for
  unambiguous divergence panels.
- The plan is 100%-parity-capable AND net-negative in complexity:
  every phase ends with something RETIRED.

## 10. Phase I results (executed 2026-07-03)

**Write census (the blindspot, closed):**
- back4-api: users, user_roles, products, product_families, clients,
  production_orders (+ sap_13 sync) — reference-plane writes; all
  target tables already in the consolidated shape.
- primary-api & reports: no raw SQL writes found (ORM/read-path
  verification = residual check, low risk).

**Consumer sweeps — two plan-changing finds:**
1. **front4 executes GraphQL directly against PROD Hasura Cloud**
   (`gqlpiot.packiot.com/v1/graphql`, raw fetch — no client lib, which
   is why the Hasura review's package-grep missed it). Overview
   V4/V5/V6 + Granado pages; 12 exported queries in V6 alone, reading
   the UNS current family. CONSEQUENCES: (a) prod Hasura retirement
   requires porting front4's full query surface (task #86 scope +=
   front4 enumeration — the prod console query-log will show it);
   (b) staging's 14+5 minimal set is unaffected (front4 targets prod
   Cloud, not staging).
2. **UNS current family: PORT, not collapse** — confirmed real
   consumers (front4 overviews). P3c strategy fixed: Go refreshers.

**sync_06 writers captured**: update_piot_table_production_data_sync_
enterprise_06 (20.6KB) + _70days variant (20.9KB) — two further
P4/Wave-2 ports.

**Homes (§5) status**: user_logs = edge-api-at-flip (decided);
uns_metrics = port (10.5) since UNS plane is consumer-confirmed;
history copy = decided; mirror-worker = stays, repointed.
