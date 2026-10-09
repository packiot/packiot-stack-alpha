# Task #224 — analytics clean-schema P4/P5 tail (STAGING `packiot_analytics`)

**Status (2026-09-08).** Sole-owner session. Hardproof-gated, expand/contract throughout.
Prior work: PR #1136 applied the subordinate renames + 11 provision-proc `PERFORM new()`
shims + 28 `h_piot_*` drops (live). `silver.*` + `serving.*` surfaces are live; read-api on
`serving.*`. This doc records what this session did and the exact remaining plan for the
items that are epics / stopped at a reversible boundary.

DB access: `aws ssm ... AWS-RunShellScript` → on-box `docker run --rm postgres:16-alpine psql
"$AGENT_REGISTER_DSN"` (DSN = `.../packiot_analytics` @ 10.10.10.89). Helpers used this session:
`/tmp/t224-psql.sh` (tab), `/tmp/t224-psql-fmt.sh` (aligned), `/tmp/t224-ssm.sh` (remote bash).

---

## Item 2 — proc-shim contract — DONE

**Expand (repoint), PR #1143 (merged → staging deploy):** `services/stream-engine/internal/rollup/provision.go`
`provisionFns` repointed from the 11 `piot_create_*_runtime_*` shims to the canonical
`piot_create_*_oee_*` procs directly.

**Writer-audit (hardproof, all live):**
- The 11 old names are byte-verified 1-line shims: `BEGIN PERFORM public.<new>(); END`.
- No DB-internal dispatcher calls any provision proc (`pg_proc` body scan over
  `prokind IN ('f','p')` = 0 rows); no view/matview references them.
- `track_functions=pl`; the only external caller is stream-engine.
- The deployed binary (docker cp + `grep -aoE`) contained the OLD names → shims were
  load-bearing → repoint-then-drop ordering enforced (#186).
- `pg_stat_user_functions`: the 11 `*_oee_*` procs carry the real bodies (33–36 historical
  calls); shims 0.

**Contract (drop 11 shims):** applied as live DDL after deploy-proof + committed migration
`db/migrations/t224-contract-provision-shims/`. No-CASCADE drop success = 0 dependents.

**Forward-port (NOT applied to live; greenfield only):** `db/init-f3/snapshot/00-packiot_analytics-schema.sql`
and `edge-node-red/db/20-oee-engine-parity.sql` still define the OLD `*_runtime_*` proc names
(and dead area/site hour/week/month variants #186-removed from provisioning). These are
fresh-init artifacts, not applied to the already-renamed live DB; they reconcile at
snapshot-regen (cutover gate, plan §6 P0b). Do NOT hand-edit the generated 00-snapshot.

---

## Item 1 — SAP fold — SAFE RE-HOME PLAN (expand ready)

**Finding.** `customer_reports.{sap_data_sync,boxes,shift,speed}` already exist as EMPTY
scaffold tables (0 rows, no triggers, no writers, unreferenced by read-api) with a
`customer_id` + (for sap_data_sync) `data_type` discriminator — a prior partial attempt that
was never wired. The 5 public views remain the LIVE source. read-api `external.go` reads only
3 of the 5 as `SELECT * FROM <view> [WHERE id_equipment=$1]`:
- `v_13_site_deb_sap_report` (neopac `/ext/neopac/sap-report`, ent 13 site 29)
- `v_sap_report_data_sync_customer_13` (neopac `/ext/neopac/sap-report-sync`, ent 13 site 13; German cols linie/auftrag/tag/shicht/shicht_nummer)
- `v_piot_production_data_sync_cust6` (montebello `/ext/montebello/data-sync`, ent 6)

`v_sap_report_data_sync_customer_13_deb` and `equipment_boxes_cust_13` are NOT read by
read-api; the latter is heavily entangled in the edge-node-red parity/greenfield universe
(defined there as a TABLE written by `upsert_equipment_boxes_cust_13()`), and is a VIEW on
staging — a divergence that makes it UNSAFE to fold blindly.

**Recommended fold = contained 1:1 re-home (NOT internals generalization).** Generalizing the
hardcoded `id_enterprise=13/site=29` CTE logic across customers risks wrong SAP numbers for a
live customer report. Instead:
1. Expand: `CREATE VIEW customer_reports.sap_site_report / sap_data_sync / production_data_sync`
   with the SAME bodies as the 3 read views, adding a constant `customer_id` column (matches the
   scaffold intent). Requires first `DROP` the 3 empty scaffold tables occupying those names
   (verified 0 rows / 0 writers / 0 readers) — reversible, they are unused.
2. Prove byte-identical: symmetric-diff = 0 vs the public views across the live window, as the
   RLS role.
3. Repoint read-api `external.go` SQL strings (`SELECT * FROM v_… ` → `customer_reports.…`) +
   `backingViews` in `externalShims`; regen census/golden; `go build` + golden tests.
4. Deploy; live 200 proof on the 3 endpoints.
5. Contract: drop the 3 public views. Leave `_deb` + `equipment_boxes_cust_13` for a dedicated
   pass tied to the edge-node-red parity reconciliation (do NOT drop this session).

Stopped at expand-ready boundary (design proven, no live change) to avoid rushing a live
customer SAP endpoint in the same session as the ingestion-adjacent work.

---

## Item 3 — column rename `oee_quality/availability/performance → oee_q/a/p` — EXPAND/CONTRACT PLAN

Target table: `public.production_orders` (cols today: `oee`, `oee_quality`, `oee_availability`,
`oee_performance`, `oee_processed`). LIVE oeecloud writer + Superset `bi.*` reader.

**Phase E1 (expand, additive/reversible):** `ALTER TABLE production_orders ADD COLUMN oee_q
double precision, oee_a double precision, oee_p double precision;` backfill
`oee_q=oee_quality` etc.
**Phase E2 (dual-write):** add a `BEFORE INSERT OR UPDATE` trigger that mirrors old↔new both
directions (so the un-repointed live writer keeps both columns coherent). Keeps `bi.*`
security-DEFINER (do NOT flip to invoker — deployed Superset is dark-schema).
**Phase R (repoint):** repoint the oeecloud writer to set `oee_q/a/p`; repoint `bi.*` + any
`serving.*`/consumer reads to new cols; prove equivalence (both columns equal on new rows).
**Phase C (contract):** drop the dual-write trigger, then `DROP COLUMN oee_quality,
oee_availability, oee_performance`. 42P01/42703 log-watch clean first.

Also flagged in plan §4 (defer to a later pass, not this rename): `production_orders_runtime`
plural-dup `id_production_orders_runtime`; `equipment_oee_shift` dual `ts_range` vs
`ts_value+ts_end`.

---

## Item 4 — `packml_register → topic_routing` — DE-RISKED PLAN (do NOT force live)

**Verdict: PLAN only.** `packml_register` is the live SparkPlug-topic→equipment router on the
hot ingestion path. Consumers span ~25 sparkplug-decoder files (birth/birthbind, refdataresolver,
agentcfg register/cutover, onboard, capture_pg, clientdescriptor, opcua/modbus/s7 pollers,
decision_tree) + stream-engine (tenants allowlist/discovery, pocontrol/topology, sparkplug/parse,
writers) + edge-api DAOs (`commands-dao`). A table rename cannot be proven zero-downtime for the
live decoder in one session — a bad flip mid-ingest starves `equipment_values`.

**Safe expand/contract cutover (multi-deploy, ingestion-watched):**
1. Expand: `CREATE VIEW public.topic_routing AS SELECT * FROM packml_register` — an
   auto-updatable view (single base table, no expr cols) so DML passes through. VERIFY the
   decoder's write paths: plain `INSERT/UPDATE` and `ON CONFLICT(col)`/bare pass through an
   auto-updatable view; `ON CONFLICT ON CONSTRAINT` does NOT (proven earlier) — audit
   `agentcfg/register.go`, `birthbind.go`, `capture_pg.go` write shapes first.
2. Migrate readers/writers service-by-service to the new name `topic_routing`, behind the view,
   deploying + watching `equipment_values` landing rate (before/after delta must stay flat) after
   EACH service. Order: read-only consumers first (stream-engine tenants/pocontrol, edge-api
   DAOs), then the decoder write paths last.
3. Once every service references `topic_routing`, swap: rename the base table
   `packml_register → topic_routing` inside a txn with `lock_timeout` + retry (proven on the
   runtime_→oee_ live rename), and drop the transitional view in the same txn (or convert the
   view to the table via a brief `DROP VIEW; ALTER TABLE RENAME`). Prove ingestion never stalls
   (watch `equipment_values` max(ts) advancing throughout).
4. Contract the dead value-cache tail cols (plan §5): `sparkplug_json, signal_quality, value,
   timestamp, ts_quality, mqtt_topic, attributed, line_unit_seq` — separate writer-audited drop.

**Same-family merges (also PLAN):** `equipment_events + equipment_events_man` (add `is_manual`
discriminator, dual-write, repoint the UNION readers, drop `_man`); the 3 target tables
(`production_targets/oee_targets/scrap_targets`) → `targets(kind, scope, vl_*)`.

Prod runs OLD-named containers (`edge-transformer`/`oeecloud-worker`) → forward-port the
`sparkplug-decoder`/`stream-engine` name in the same prod deploy; do NOT cut over prod here.

---

## Item 5 — `ca_agg → silver` rollup migration — CONCRETE PLAN (EPIC, do NOT drop ca_agg)

**Verdict: PLAN only.** `ca_agg_equipment_values_1min/_1hour` are the live rollup source. `silver`
already exists as VIEWS: `equipment_metrics_{1min,10min,1hour,1day}` +
`equipment_categorical_{1min,10min,1hour}`. The rollup engine reads ca_agg in ≥10 stream-engine
files.

**What the rollup reads from ca_agg (the contract silver must satisfy):**
| Consumer file | cagg tier | columns read |
|---|---|---|
| `rollup/availability.go` | 1min | `id_equipment, ts_value, gross_production_incr` (islanding: `gross_production_incr>0`, gap between successive `ts_value`) |
| `rollup/hour.go` (values) | 1hour | `sum(gross_production_incr)`, `sum(net_production_incr)` per `(id_equipment,ts_value)` |
| `rollup/hour.go` (speed) | 1min | `ideal_production_speed` (LOCF from `equipment_values`), `speed`; avg per hour |
| `rollup/hour.go` (events last_seen) | 1hour | `max(ts_value)` per equipment (trailing-open bound) |
| `rollup/inferspeed.go`, `line_lead.go`, `shift.go`, `uns/uns.go`, `events/closer.go`, `events/cpac_deriver.go`, `config.go`, `cmd/port-parity` | 1min/1hour | same partials |

**silver mapping (plan §2 partials):** `sum(gross_production_incr)` → `silver.equipment_metrics_*.sum_gross`;
`sum(net_production_incr)` → `sum_net`; `avg(speed)` → `sum_speed/cnt_speed`; `max(ts_value)` →
trivially present. **GAP:** `ideal_production_speed` LOCF is NOT a decomposable sum — it is a
last-value carried forward from `equipment_values`. silver's categorical companion
(`equipment_categorical_*`, already built for the P3 serving repoint) is the right home; confirm
it exposes `ideal_production_speed` as `last()`/LOCF at each tier, else add it. The
`gross_production_incr>0` islanding predicate needs the per-minute non-zero flag preserved — the
1min tier must retain row-level (not pre-summed) gross for availability, OR availability moves to
reading a 1min gross partial with a `cnt_rows`/`sum_gross>0` proxy (VERIFY equivalence — this is
the one non-trivial semantic).

**Cutover order (incremental, each hardproofed vs the ca_agg output on a frozen window):**
1. Add a refresh policy to EVERY silver tier + a boot/CI "every real-time cagg has a policy"
   assertion (#196/#206 root cause) — silver tiers are currently VIEWS; confirm whether they are
   real caggs or plain views before relying on them for the rollup.
2. Port the READ-ONLY hour values pass (`hour.go` sums 1hour) first — lowest risk, pure sum.
3. Port availability (1min islanding) — needs the gross-nonzero semantic proof.
4. Port speed/ideal_speed (needs categorical LOCF).
5. Port the remaining consumers (inferspeed/line_lead/shift/uns/closer/cpac_deriver/port-parity).
6. Only after ALL consumers read silver + a full recalc parity run: writer-audit + drop
   `ca_agg_equipment_values_1min/_1hour` (a real-time cagg → prove consumers first, #196). Keep
   ca_agg live until then.

This is multi-session. A safe incremental first step (item 5.2, the pure-sum hour values pass) is
the recommended next execution unit.
