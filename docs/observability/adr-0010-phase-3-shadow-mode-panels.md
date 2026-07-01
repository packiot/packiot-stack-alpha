# ADR-0010 Phase 3 — Shadow-mode observability panels

Grafana panel specs for the 30-day comparator soak that gates Phase 4
cutover. Runs against Prometheus scraping `edge-transformer:9102/metrics`.

**Target dashboard:** `/d/edge-transformer-shadow-mode` (create new)

**Guardrail metrics** exposed by edge-transformer when `USE_GO_PORT=true`:

| Metric | Type | Labels | Purpose |
|---|---|---|---|
| `calc_evaluations_total` | counter | `tenant, kind, outcome={send,drop}` | Every Calc() call — Decision.SendDownstream|
| `calc_metrics_emitted_total` | counter | `tenant, kind` | Per-metric entry from Decision.Metrics — compares 1:1 vs Node-RED emission rate |
| `calc_state_mutations_total` | counter | `tenant, mutation_kind` | State writes — divergence signal for missed updates |
| `calc_state_seeds_total` | counter | `tenant, seed_kind` | Non-counter metrics that seeded State (MachSpeed, Parameters) |
| `calc_errors_total` | counter | `tenant, reason` | **Must stay near 0** — ANY non-zero rate = investigation |

---

## Panel 1 — Evaluation rate by outcome

**Question**: Is the Go port evaluating every counter metric that flows through?

**PromQL** (5-min rate per tenant, stacked by outcome):

```promql
sum by (tenant, outcome) (rate(calc_evaluations_total[5m]))
```

**Threshold interpretation**:
- `outcome="send"` rate ~= Node-RED publish rate on `edge.plc-normalized` (should track 1:1)
- `outcome="drop"` rate: expected non-zero (SETUP mode, glitch guard, no-increment). Should stabilize; sudden spike = bug
- Zero rate on both = port not receiving anything (upstream issue)

**Panel type**: Time-series, stacked area, per-tenant.

---

## Panel 2 — Metric emissions vs Node-RED rate

**Question**: Does the Go port's per-metric emission match Node-RED's actual publish rate?

**PromQL** — Go port emission rate:

```promql
sum by (tenant, kind) (rate(calc_metrics_emitted_total[5m]))
```

**PromQL** — Node-RED equivalent (approx via shadowpub publish rate):

```promql
sum by (tenant) (rate(shadowpub_published_total[5m]))
```

Overlay both on same Y axis. In stable state they should match within the same 5-min bucket.

**Alert threshold**: divergence > 1% over any 30-min window → red alert.

**Panel type**: Time-series, two overlaid lines.

---

## Panel 3 — State mutations heatmap

**Question**: Which parts of the port are actively writing state? Is the write pattern consistent?

**PromQL**:

```promql
sum by (mutation_kind) (rate(calc_state_mutations_total[5m]))
```

Mutation kinds to expect (from calc.go Phase 5 + 6 + 10):
- `counter.processed` / `.consumed` / `.defective` — per counter tick
- `counter.custom_30772` — only if Parameter*30770*=true units present
- `speed.ts` / `speed.value` — per counter tick after first
- `speed.ts_first` — one-shot per unit at startup
- `status.topics` — one-shot per status-crossing topic

**Threshold interpretation**:
- Absence of `counter.*` mutations while `calc_evaluations_total{outcome="send"}` is non-zero → State write bug
- `speed.ts_first` should be a bounded set (one per unit), then plateau

**Panel type**: Heatmap, mutation_kind on Y axis, rate on color intensity.

---

## Panel 4 — Error rate (must stay near 0)

**Question**: Is the port producing evaluation errors?

**PromQL**:

```promql
sum by (tenant, reason) (rate(calc_errors_total[5m]))
```

**Alert threshold**: **ANY non-zero rate over 15 minutes → page**. Reasons to expect:
- `bool_as_counter` — upstream config error (bool metric hitting counter path)
- `non_numeric_value` — same class of upstream issue
- `mutation_apply` — State write failed; investigate State backend

**Panel type**: Time-series, one line per reason, with red-fill above 0.

---

## Panel 5 — State seed hit rate

**Question**: Are non-counter Sparkplug metrics being captured so the counter evaluations have context?

**PromQL**:

```promql
sum by (tenant, seed_kind) (rate(calc_state_seeds_total[5m]))
```

Seed kinds:
- `machspeed` — MachSpeed reads from PLC
- `threshold_quant` — Parameter*30750*
- `threshold_mode` — Parameter30758
- `external_speed_flag` — Parameter*30761*
- `counter_multiplier` — Parameter*30710*

**Threshold interpretation**:
- `machspeed=0` for extended periods while `calc_evaluations_total{outcome="drop"}` is high → NBIRTH missing or wrong metric name pattern
- Sudden zero on all seeds → NBIRTH cache miss (edge-transformer restart without retained state)

**Panel type**: Time-series, per seed_kind.

---

## Panel 6 — Health status timeline

**Question**: Is edge-transformer's aggregated /healthz reporting healthy?

**PromQL** — component-level:

```promql
edge_transformer_component_healthy{component=~"mqtt_subscriber|shadow_publisher|amqp_consumer"}
```

**Panel type**: State timeline (green/red), one row per component.

---

## Dashboard JSON scaffold

Minimum-viable dashboard JSON that instantiates panels 1-4 above:

```json
{
  "title": "edge-transformer — ADR-0010 Phase 3 shadow mode",
  "tags": ["edge-transformer", "phase-3", "adr-0010"],
  "timezone": "browser",
  "schemaVersion": 39,
  "version": 1,
  "refresh": "1m",
  "panels": [
    {
      "id": 1, "type": "timeseries", "title": "Evaluation rate by outcome",
      "targets": [{"expr": "sum by (tenant, outcome) (rate(calc_evaluations_total[5m]))", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "cps"}}, "gridPos": {"x":0,"y":0,"w":12,"h":8}
    },
    {
      "id": 2, "type": "timeseries", "title": "Go port vs Node-RED emission rate",
      "targets": [
        {"expr": "sum by (tenant, kind) (rate(calc_metrics_emitted_total[5m]))", "refId": "A", "legendFormat": "go: {{kind}}"},
        {"expr": "sum by (tenant) (rate(shadowpub_published_total[5m]))", "refId": "B", "legendFormat": "shadowpub"}
      ],
      "gridPos": {"x":12,"y":0,"w":12,"h":8}
    },
    {
      "id": 3, "type": "heatmap", "title": "State mutations by kind",
      "targets": [{"expr": "sum by (mutation_kind) (rate(calc_state_mutations_total[5m]))", "refId": "A"}],
      "gridPos": {"x":0,"y":8,"w":12,"h":8}
    },
    {
      "id": 4, "type": "timeseries", "title": "Calc errors — MUST STAY NEAR 0",
      "targets": [{"expr": "sum by (reason) (rate(calc_errors_total[5m]))", "refId": "A"}],
      "fieldConfig": {"defaults": {"unit": "cps", "custom": {"fillOpacity": 30, "gradientMode": "opacity"}}},
      "alert": {"conditions": [{"evaluator": {"params": [0], "type": "gt"}, "query": {"params": ["A", "15m", "now"]}, "reducer": {"type": "avg"}}]},
      "gridPos": {"x":12,"y":8,"w":12,"h":8}
    }
  ]
}
```

Save this as `packiot-stack-alpha/grafana/edge-transformer-shadow-mode.json` and import via the Grafana provisioning system.

---

## 30-day soak success criteria

The Phase 4 cutover (per `docs/adr-0010-phase-4-migration-plan.md` §3, Step 4.2) requires:

1. **Panel 2 divergence ≤ 0.01%** averaged over the 30 days
2. **Panel 4 error rate = 0** for the entire window (no exceptions)
3. **Panel 6 mqtt_subscriber healthy** > 99.9% uptime
4. **No manual intervention required** on the port for the full 30 days

Failure of any → halt cutover + investigate before proceeding to Phase 4 Step 4.3.
