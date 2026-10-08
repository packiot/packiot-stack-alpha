# Production promotion readiness — 2026-10-08

**Status:** ASSESSMENT ONLY. Nothing here was executed on prod. All prod access was SELECT-only, inside
`BEGIN TRANSACTION READ ONLY` with `default_transaction_read_only=on`, run through `psql` in the existing
`stack-pgbouncer-1` container on the prod app box. Promotion itself needs the user's go.

## 1. Headline
- `staging` is **1,422 commits** ahead of `production` (tip `0d3872ac`, 2026-09-08).
- `production` has **55 non-merge commits** that `staging` lacks: the September cutover forward-ports, Superset
  CPACK dashboards, prod Terraform and runner, and the Firebase IdP retirement. Prod infra files differ in 79 files
  (+2,319 / −6,306). **A re-cut must reconcile them, never force-push** (memory: prod-staging divergence).
- **The prod DB lacks the medallion schema separation and everything after it.** It has 5 schemas; staging has 13.
  `public.enterprises`, `public.equipments` and the like are still in `public`, so `t231`/`t237` → `t287` are not
  applied. This promotion is a **schema cutover of about 150 migrations**, not a routine deploy.

## 2. Migration presence audit (187 migration dirs on `staging` and not on `production`)
Method (`scripts/promotion/`):
1. A read-only catalog snapshot of both DBs (`catalog-snapshot.sql`): relations, columns, functions (+ body md5),
   triggers, constraints, views, schemas, roles.
2. `migration-presence-audit.py` extracts each migration's expectations: CREATE function/table/view/index/sequence/
   schema/role/trigger, ADD COLUMN, RENAME, DROP.
3. It keeps only the expectations that **hold on staging** (calibration: 569 of 782, 73 %), so superseded and
   misparsed ones drop out.
4. It grades prod against what's left.

It cannot see data-only migrations or dynamic SQL; those come out as *unknown*. Calibration check: the only
migrations known to have been hand-applied on prod (the 09-07 cutover, `analytics-rename` 33/33 and
`analytics-186-drop` 18/18) grade **applied**.

| Status | Count |
|---|---|
| applied | 19 |
| partial | 17 (most are effectively missing with a coincidental match, e.g. `t237-core-schema` 1/19) |
| missing | 81 |
| unknown (data-only / dynamic / comment-only) | 70 |

**Applied:** `2026-09-03-operator-entities-per-site-topics.sql`, `analytics-186-drop`, `analytics-rename`, `t226-oee-qap-contract`, `t241-barcode-fold`, `t244-phase5-drop-internal-06`, `t246-drop-dead-customer-dashboards`, `t247-auth-to-identity`, `t248-drop-equipment-categorical-shims`, `t266-necessity-drops-phaseA`, `t268-drop-dead-cagg-chain`, `t270-drop-equipment-live-hour-week`, `t272-drop-customer-reports-speed`, `t273-drop-site-day-chain`, `t283-config-schema-targets`, `t-downtimes-microstops-po-join`, `tRD-appschemas-dedup-cognito-index`, `t-shift-end-range`, `t-shift-no-overlap`

**Partial** (held/calibrated · first expectations not met on prod):

| Migration | Held | Not on prod |
|---|---|---|
| `analytics-clean-schema` | 29/78 | rel:public.h_downtimes_table (should be gone); rel:public.h_piot_oee_score_data_test1 (should be gone) |
| `analytics-cruft-drop` | 2/57 | fn:public.h_piot_get_downtimes_equipment_level (should be gone); fn:public.h_piot_get_downtimes_events_3 (should be gone) |
| `machine-speed-canonical-redesign` | 1/4 | fn:serving.machine_speed; fn:public.h_piot_machine_speed (should be gone) |
| `t237-app-schema` | 3/15 | rel:public.users (should be gone); rel:public.user_roles (should be gone) |
| `t237-core-schema` | 1/19 | rel:public.areas (should be gone); rel:public.enterprises (should be gone) |
| `t237-views-schema` | 7/17 | rel:public.v_entities_per_user_role (should be gone); rel:public.v_entities_per_user_role_operator (should be gone) |
| `t241-app-split` | 2/4 | schema:config; schema:ops |
| `t242-scrap-target-arbiter-fix` | 1/2 | rel:public.scrap_targets (should be gone) |
| `t244c-serving-self-containment` | 4/10 | fn:serving.sap_report_data_sync; fn:serving.overview_takt |
| `t258-drop-dim-grain-shims` | 1/9 | rel:public.equipments (should be gone); rel:public.sites (should be gone) |
| `t261e-drop-event-shims` | 1/4 | rel:public.data_quality_event (should be gone); rel:public.equipment_events_man (should be gone) |
| `t274-drop-orphan-sequences` | 1/5 | rel:public.areas_history_history_id_seq (should be gone); rel:public.enterprises_history_history_id_seq (should be gone) |
| `t-counter-totals-readers` | 1/2 | rel:silver.equipment_values_labeled |
| `t-device-bindings` | 1/5 | rel:core.device_bindings; rel:equipments_id_equipment_id_enterprise_uq |
| `t-downtimes-by-category-ers-window` | 1/2 | fn:serving.downtime_by_category |
| `t-downtimes-category-leakproof-bounds` | 1/3 | fn:serving.downtime_by_category; rel:idx_ers_equipment_prod_day |
| `t-line-downtime-from-lead-machine` | 1/2 | col:core.equipments.downtime_from_lead_machine |

**Missing:** `t224-contract-provision-shims`, `t231-medallion-schema-separation`, `t237-barcode-schema`, `t237-stream-engine-schema`, `t239-ca-agg-retire`, `t239-tier1-dead-caggs`, `t243-drop-monitoramento-view`, `t244b-pool-indice-geral-seq`, `t244-enterprise-0613-parameterize`, `t249-drop-medallion-oee-fact-shims`, `t250-drop-production-orders-shim`, `t252-drop-medallion-shims-final`, `t257-scrap-capability`, `t258a-drop-dead-agg-10min`, `t261a-drop-dead-1min-pair`, `t261c-drop-cagg-shims`, `t265-fix-oee-score-core-equipments`, `t267-cloudbeaver-ro-role`, `t271-cloudbeaver-rw-role`, `t276-readapi-ro-nobypassrls`, `t282-historian-gateway-glue`, `t284-eliminate-live-h-carriers`, `t285-eliminate-shift-day-h-carriers`, `t-adr0061-p3a-operator-by-id`, `t-adr0061-p3b-entities-hierarchy-ids`, `t-adr0061-p3c-po-list-by-id`, `t-adr0062-p1-po-number-expand`, `t-adr0062-p3b-report-label-safe-cast`, `t-analytics-history-backfill`, `t-availability-display`, `t-availability-exclusions`, `t-backfill-production-targets-default`, `t-bispharma-menu-leak-fix`, `t-bispharma-mock-rated-speeds`, `t-bispharma-operator-readiness`, `t-counter-totals-float8`, `t-cpack-reason-catalog`, `t-data-invariants`, `t-data-sync-po-start-date`, `t-deriver-phantom-running-cleanup`, `t-device-key-resolver`, `t-device-resolver-enterprise`, `t-downtime-events-materialization`, `t-downtime-resolved-unique`, `t-ent5-area-day-begin-align`, `t-ent5-demo-readiness`, `t-equipment-values-speed-idx`, `t-events-timeline-bound`, `t-events-view-line-attribution-dedupe`, `t-history-uncap`, `t-line-lead-counter-roles`, `t-line-lead-net-machine`, `t-line-meter-fill`, `t-mission-control-lead-timeline`, `t-mission-control-pq`, `t-mission-control-prev2-from-gold`, `t-mission-control-speedless-timeline`, `t-mission-control-status24h-perf`, `t-mission-control-status-labels`, `t-mission-control-timeline-threshold-units`, `t-oee-aggregate-unbiased`, `t-operator-events-dedupe`, `t-operator-po-list-real-order`, `t-operator-replace-runtime`, `t-plc-link-health`, `t-po-availability-exclusions`, `t-po-runtime-fk-index`, `tRD-silver-bronze-state-labeled-view`, `t-replicate-manual-events`, `t-report-hour-from-gold`, `t-retention-catalog`, `t-sandbox-attribution-sync`, `t-sandbox-grace-hold`, `t-sandbox-hold-mode`, `t-sandbox-reflect-catalog-extras`, `t-sandbox-reflection`, `t-scrap-spike-guard`, `t-scrap-spike-guard-per-measure`, `t-serving-group-by-case-insensitive`, `t-serving-hour-grain-production-day`, `t-serving-lookups-leakproof-hour-fix`

**Unknown:** `analytics-cagg-refresh-policies`, `analytics-hardening`, `operator-pw-hash-retirement`, `_probes`, `t224-po-oee-column-rename`, `t237-silver-schema`, `t243-topic-routing-pk-rename`, `t251-restore-premature-shim-drops`, `t253-drain-stale-open-events`, `t256-drain-phantom-hour-recalc`, `t261b-caggs-to-silver`, `t261d-event-tables-to-silver`, `t271-historian-promoted-allowlist`, `t275-schema-docs-complete`, `t277-customer-reports-object-docs`, `t278a-core-object-docs`, `t278b-gold-object-docs`, `t278c-silver-bronze-object-docs`, `t278d-app-planes-object-docs`, `t278e-serving-bi-public-object-docs`, `t278f-schema-comment-corrections`, `t278g-core-customer-reports-column-fill`, `t279-core-enum-column-resolve`, `t280-serving-security-invoker`, `t281-gold-poid-int8-fk`, `t286-boxes-to-bronze`, `t287-historian-cold-schema`, `t-adr0061-p3c2-po-number-text`, `t-adr0061-p3d-bindings-backfill`, `t-adr0062-p3a-order-number-readers`, `t-adr0062-sandbox-twin-po-uuid`, `t-backfill-cd-equipment`, `t-backfill-equipment-config-defaults`, `t-counter-totals-cagg-deprecation`, `t-counter-totals-float8-public`, `t-cpack-backfill-po-runtime-windows`, `t-cpack-net-machine-meter-lines`, `t-data-invariants-timing`, `t-data-invariants-v3`, `t-data-invariants-v4`, `t-data-invariants-v5`, `t-data-invariants-v6`, `t-data-invariants-v7`, `t-data-invariants-v8`, `t-descriptor-device-keys`, `t-ent5-counters-only-status-and-threshold`, `t-ent5-downtime-reason-catalog`, `t-ent5-downtime-reasons-json`, `t-ent5-downtime-threshold-reliable-feed`, `t-ent5-enable-event-display`, `t-ent5-l90-lead-display`, `t-ent5-lead-event-display`, `t-ent5-line-lead-repoint`, `t-ent5-shift-size-backfill`, `t-equipments-self-fks`, `t-histdb-object-docs`, `t-historian-serving-guards`, `t-historian-svc-hardening`, `t-i18n-availability-states`, `t-i18n-ptbr-missing-desktop-keys`, `t-ideal-speed-best-demonstrated`, `t-no-data-status`, `t-oee-uncapped-data`, `t-plc-link-health-rls`, `t-po-runtime-exclusion-not-null-fk`, `tRD-core-gold-column-hardening`, `tRD-silver-bronze-drop-bogus-idequip-default`, `t-rls-initplan-policies`, `t-tidy-schema-docs`, `t-topic-routing-guards`

Not every staging migration belongs on prod. Tenant-specific data fixes (`t-ent5-*`/Bispharma, `t-sandbox-*`, CPACK
data repairs computed from staging's replicated rows) need a per-item decision.

### 2b. Hard-coded surrogate ids (do the staging migrations travel?)
Every `id_* = <literal>` / `IN (…)` in the 187 migrations (11 migrations). Prod has enterprises 1 and 3 only.
| Migration | Literal ids | On prod |
|---|---|---|
| `t-adr0062-p1-po-number-expand` | PO `101585550` (staging +100 M replica offset) | **would have failed** (prod PO is `1585550`) → fixed by #1635 (business key) |
| `t-ideal-speed-best-demonstrated` | equipment 90, 107 (+ Bispharma 2000xxx) | **applies correctly**: prod 90 = ISIMAT, 107 = SLEEVE1 (same CPACK ids), still at the old speeds 70/90, and each UPDATE is compare-and-set |
| `t-ent5-l90-lead-display` | Bispharma 2000329/2000330 | no-op (no ent 5 on prod): staging-only |
| `t-data-invariants*` (8) | sandbox ent 2000003 | harmless exclusion (no twin on prod) |
| `t244c-serving-self-containment` | ent 13 (Neopac) | frozen legacy SQL; stable tenant id |

Side finding: `core.equipments.cd_equipment` is **empty on prod** (staging: `ISIMAT`, `SLEEVE1`) →
`t-backfill-cd-equipment` (graded *unknown*: data-only) is needed there.

## 3. ADR-0061 / ADR-0062 prod preflight (read-only, 2026-10-08)
| Check | Prod | Consequence |
|---|---|---|
| POs / no text number / `id_order = 0` / alphanumeric | 19,789 / 4,059 / 1 / 2 | the P1 backfill fills the 4,059 |
| Duplicate client numbers | **1 group**: ent 3 `889185` on POs 1574989 + 1585550 | D5. The P1 file had staging-only ids (`101585550`); **fixed by #1635** (business key), red/green on prod's exact shape |
| `numeric text ≠ int` | 4 | expected legacy drift; text wins (D1) |
| `core.device_bindings` | **absent** | ADR-0061 P0 + `t-adr0061-p3d-bindings-backfill` must run **before** the new decoder (64 equipments, 123 active register rows) |
| Enterprises with POs | 1, 3 | |

## 4. Ordering constraints known today
1. Schema migrations in staging's order (`t231` → `t287` …), with tenant-specific ones decided item by item.
2. ADR-0061: `t-device-bindings` → bindings backfill → `t-device-resolver-enterprise` → the decoder image.
3. ADR-0062: `t-adr0062-p1-po-number-expand` (with #1635) **before** the edge-api image. Its knex migration
   `20261008000001` throws on duplicate numbers unless the trigger already exists. Then P3a and P3b. P3b goes before
   the stream-engine image that carries `sap13_body.sql`.
4. Long DDL waits for any running `pg_dump` (AccessShare on every table) and uses `lock_timeout` + retry.
5. Never `decompress_chunk` on the shared Timescale DB.

## 5. Decisions needed (user)
- How to run the schema cutover: **ordered replay** of the missing migrations (with per-item applicability) or a
  **schema transplant** (`docs/adr/reference/production-f3-schema-assembly.md` style), and the downtime window.
- Branch strategy: merge `staging` → `production`, reconciling the 55 prod-only commits.
- Whether tenant-specific migrations (`t-ent5-*`, sandbox, CPACK repairs) apply to prod.

Re-run before the promotion: snapshot both DBs (SELECT-only), then
`scripts/promotion/migration-presence-audit.py <dir with staging.tsv, prod.tsv, newmig.txt>`.
