# Manual smoke check — is the stack alive and is the data flowing?

- **What this is**: the 10-minute hop-by-hop manual verification of the
  staging stack, layer by layer. Run it after a deploy, after an
  incident, or whenever a dashboard smells wrong.
- **What this is NOT**: a correctness proof. Freshness checks find
  *where* a pipe is broken; the **comparator** finds *whether* the
  water is clean (layer 4). Never hand-diff what the bake diffs
  exhaustively.
- First run 2026-07-06 (all green); baseline numbers below are from
  that run — expect the same order of magnitude, not the same values.

## Layer 0 — is everything up? (app EC2 via SSM)

```bash
docker ps --format '{{.Names}} {{.Status}}' | grep -v healthy
```

Want: only the containers that legitimately have no healthcheck
(adminer, operator, promtail, plc-sim, simulator, pgbouncer,
authentik-redis, edge-api/nodered legacy pair). Anything `Restarting`
or `unhealthy` = stop here and read its logs.

## Layer 1 — ingest freshness, per flow (DB EC2)

Run against **each** flow — `packiot` (F1), `shadow_go_port` schema on
packiot (F2), `packiot_shadow` (F3):

```sql
SELECT max(ts_value) AS newest,
       count(*) FILTER (WHERE ts_value > now() - interval '15 min') AS rows_15min
FROM equipment_values;   -- F2: FROM shadow_go_port.equipment_values
```

Good: `newest` under ~2 min old; similar `rows_15min` across all three
(triple-emit fans out the same traffic — baseline ~250/15min).
Diagnosis: one flow dry = that leg's consumer/routing; all flows dry =
upstream (plc-sim → mosquitto → edge-transformer → RabbitMQ). Heavy
SQL transport pattern: `scripts/ssm-psql.sh` (base64 → docker cp →
psql — never heredoc without `-i`).

## Layer 2 — per-tenant freshness (is CPACK flowing?)

```sql
SELECT id_enterprise, count(*), max(ts_value)
FROM equipment_values
WHERE ts_value > now() - interval '1 hour'
GROUP BY 1 ORDER BY 1;

-- CPACK-Staging (enterprise 3) arrives via the MIRROR path, not MQTT:
SELECT count(*), max(ts_event) FROM equipment_events
WHERE id_enterprise = 3 AND ts_event > now() - interval '24 hours';
```

Baseline: CPACK ~600+ events/24h, newest minutes old. Remember the
paths differ: simulated tenants come over MQTT; CPACK comes from prod
via mirror-worker. A CPACK gap with healthy MQTT tenants = look at
mirror-worker, not the transformer.

## Layer 3 — engine heartbeat

```sql
SELECT count(*) FROM equipment_runtime_1hour
WHERE ts_value > now() - interval '2 hours';   -- thousands = jobs ticking
```

```bash
docker logs oeecloud-worker --since 30m 2>&1 | grep -iE 'panic|level=ERROR'  # want: nothing
```

Report pools on staging (`customer_reports.shift/speed/sap_data_sync`)
at **0 rows is EXPECTED** — staging's enterprise 6/33/13 base data
aged past the report windows. Their correctness evidence is the
prod-read harness (layer 4), not staging row counts.

## Layer 4 — correctness (the real answer)

- **Grafana `/d/bake-flow-parity`** — 10 fidelity surfaces + 3
  identity fingerprints. The discipline: every non-zero surface must
  keep its *named, dated* cause (09-bake rule).
- **Report writers**: `./scripts/powerbi-evidence-prod-read.sh`
  (SELECT-only vs prod; baselines: shift06 ~98.6% exact — the
  remainder is the moving-base artifact class, speed33 ~96%).
- **Façade surface**: `./scripts/test-powerbi-compatibility.sh`
  (30-object × 5-dimension gate report).

## Layer 5 — consumer smoke

1. Operator UI: start/stop a test PO → watch it land in `user_logs`
   (edge-api) → `production_orders` + runtime window on F3 within
   seconds. One gesture exercises the whole control plane.
2. One GraphQL query in the staging Hasura console (read side).
3. Glance at any product dashboard reading the consolidated flow.

## Known footguns when reading results

- **Never SUM whole tables on F1** — `production_orders_runtime` there
  carries 3 pre-guard oscillator-era rows with |gross| > 1e12 (a naive
  SUM returns ~8e22). F1 retires at the flip; the guards prevent new
  ones. Filter `abs(x) < 1e12` if you must aggregate F1 history.
- `uns_equipment_current_metrics` rows only update when THAT machine
  sends data — a stale row usually means an idle (simulated)
  equipment, not a broken refresher. Check the spread, not min().
- After a RabbitMQ restart, confirm layer 1 freshness rather than
  trusting container status — reconnects are automatic but verify.
- F1 vs F3 raw row counts differ BY DESIGN (F3 splits history into
  `hist_*` tables). Identity comparisons belong to the bake
  fingerprints, not ad-hoc counts.

Routing: this is layer-by-layer triage. For what each component *is*,
see [the guide](../README.md); for the verification methodology
behind layer 4, [the guide ch.8 — observability](../guide/08-observability.md).
