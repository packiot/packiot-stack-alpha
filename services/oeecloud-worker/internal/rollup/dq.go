// dq.go — the data-quality alarm substrate (north-star P11 andon pillar, Tier-0).
//
// PURPOSE (instrument-before-remediate): the served OEE plane currently carries
// silent corruption — oee up to 8.2e18, net > gross, negative counts/durations,
// ~90% NULL/0 ideal_speed — with NO signal anywhere. This file makes that
// corruption VISIBLE by DETECTING it per computed grain-row and RECORDING a
// `data_quality_event` (upsert). It is a PURE SIDE-WRITE:
//
//	IT NEVER CLAMPS, ALTERS, OR DROPS ANY equipment_runtime_*/agg_* VALUE.
//
// The served numbers are byte-identical before and after this runs. We measure
// the corruption first, under a visible baseline, THEN remediate separately.
//
// TWO LAYERS, deliberately split:
//   - DetectGrain — a PURE function (no DB) over one grain row's metrics; the
//     single source of truth for the predicates, fully unit-testable (dq_test.go).
//   - RunDQScan — reads recently-computed grain rows back (read-of-runtime),
//     runs DetectGrain per row, and UPSERTs the events. Bounded window + LIMIT
//     per grain so a tick is cheap. Idempotent via the dedup unique index
//     (migration 34) so recompute never piles duplicates.
package rollup

import (
	"context"
	"fmt"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

// DQRule is the text enum stored in data_quality_event.rule (mirrors migration 34).
type DQRule string

const (
	// DQRuleOEEGt1 — oee (or the oee_p/oee_a/oee_q factors) exceeds 1.0. A served
	// efficiency claim above 100% is physically impossible; the 8.2e18 outliers land here.
	DQRuleOEEGt1 DQRule = "OEE_GT_1"
	// DQRuleNetGtGross — net_count > gross_count, i.e. quality (net/gross) > 1.
	DQRuleNetGtGross DQRule = "NET_GT_GROSS"
	// DQRuleNegativeMetric — any count or duration below zero.
	DQRuleNegativeMetric DQRule = "NEGATIVE_METRIC"
	// DQRuleIdealSpeedNullProducing — ideal_speed IS NULL or 0 while net > 0 (P3-4).
	// The OEE denominator collapses → oee silently 0 (or divide-by-zero-guarded loss).
	DQRuleIdealSpeedNullProducing DQRule = "IDEAL_SPEED_NULL_WHILE_PRODUCING"
	// DQRuleMetricMissingAllLevels — a metric present at no aggregation level (P3-2).
	// RESERVED: this is a CROSS-LEVEL condition (a value that appears in no grain at
	// all), not cheaply detectable from a single grain row, so DetectGrain does NOT
	// fire it. The constant + column exist so the table/read-path already model it;
	// a future cross-level scan can emit it without a schema change.
	DQRuleMetricMissingAllLevels DQRule = "METRIC_MISSING_ALL_LEVELS"
)

const (
	dqSevWarn  = "warn"
	dqSevError = "error"
)

// GrainMetrics is ONE computed runtime grain row, as read back AFTER the rollup
// wrote it. It is the pure input to DetectGrain — no DB handle, no I/O.
type GrainMetrics struct {
	IDEnterprise int
	IDEquipment  int
	Grain        string
	BucketTS     time.Time

	// The four OEE factors as written to the served row.
	OEE  float64
	OeeA float64
	OeeP float64
	OeeQ float64

	Gross float64
	Net   float64

	// IdealSpeed is nullable in the DB (nil ⇒ SQL NULL). In the runtime tables it
	// defaults to 0, so the "0 while producing" branch is the common one; nil is
	// handled for robustness.
	IdealSpeed *float64

	// Count/duration metrics checked for negativity.
	AvailableTime   float64
	RunningTime     float64
	StoppedTime     float64
	PlannedDowntime float64
	Downtime        float64
	ChangeoverTime  float64
	IdleTime        float64
}

// DQEvent is one detection to record. ObservedValue is nil ⇒ SQL NULL.
type DQEvent struct {
	IDEnterprise  int
	IDEquipment   int
	Grain         string
	BucketTS      time.Time
	Rule          DQRule
	ObservedValue *float64
	Severity      string
}

// DetectGrain applies every data-quality rule to one computed grain row and
// returns the events that fired (empty for a clean row). PURE — the single
// source of truth for the predicates, exercised directly by the unit tests.
//
// It DETECTS ONLY. It returns what to record; it changes no input value.
func DetectGrain(m GrainMetrics) []DQEvent {
	var out []DQEvent
	emit := func(rule DQRule, sev string, obs *float64) {
		out = append(out, DQEvent{
			IDEnterprise: m.IDEnterprise, IDEquipment: m.IDEquipment,
			Grain: m.Grain, BucketTS: m.BucketTS,
			Rule: rule, ObservedValue: obs, Severity: sev,
		})
	}

	// OEE_GT_1 — any of the four factors above 1.0 (100%). Report the WORST so the
	// observed_value carries the magnitude of the outlier (the 8.2e18 case).
	worst := m.OEE
	for _, f := range []float64{m.OeeA, m.OeeP, m.OeeQ} {
		if f > worst {
			worst = f
		}
	}
	if worst > 1.0 {
		v := worst
		emit(DQRuleOEEGt1, dqSevError, &v)
	}

	// NET_GT_GROSS — quality > 1 is physically impossible. observed = the overshoot.
	if m.Net > m.Gross {
		v := m.Net - m.Gross
		emit(DQRuleNetGtGross, dqSevError, &v)
	}

	// NEGATIVE_METRIC — any count/duration below zero. Report the most-negative.
	minNeg := 0.0
	hasNeg := false
	for _, v := range []float64{
		m.Gross, m.Net, m.AvailableTime, m.RunningTime, m.StoppedTime,
		m.PlannedDowntime, m.Downtime, m.ChangeoverTime, m.IdleTime,
	} {
		if v < 0 {
			hasNeg = true
			if v < minNeg {
				minNeg = v
			}
		}
	}
	if hasNeg {
		v := minNeg
		emit(DQRuleNegativeMetric, dqSevError, &v)
	}

	// IDEAL_SPEED_NULL_WHILE_PRODUCING (P3-4) — producing (net > 0) but no ideal
	// speed → OEE denominator collapses. warn: it is the pervasive baseline (~90%),
	// silent loss rather than an impossible served value.
	if m.Net > 0 && (m.IdealSpeed == nil || *m.IdealSpeed == 0) {
		var obs *float64
		if m.IdealSpeed != nil {
			z := *m.IdealSpeed
			obs = &z
		}
		emit(DQRuleIdealSpeedNullProducing, dqSevWarn, obs)
	}

	return out
}

// dqGrainScan defines one runtime grain table to scan, with the recency window
// (interval string) bounding how far back a tick looks. Windows are generous
// enough that the first tick surfaces the standing corruption (proof of
// visibility), and dqScanLimit caps the per-grain row count so the side-write
// stays cheap.
type dqGrainScan struct {
	Grain  string
	Table  string
	Window string
}

var dqGrainMatrix = []dqGrainScan{
	{"shift", "equipment_runtime_shift", "30 days"},
	{"hour", "equipment_runtime_1hour", "7 days"},
	{"day", "equipment_runtime_1day", "30 days"},
	{"week", "equipment_runtime_1week", "180 days"},
	{"month", "equipment_runtime_1month", "365 days"},
}

// dqScanLimit caps rows read per grain per tick (most-recent-first). A bound on a
// pure side-read; it never changes any served value.
const dqScanLimit = 20000

// dqGrainScanSQL reads recently-computed grain rows, joining equipments for the
// tenant id. %[1]s = EvSchema (flow tables), %[2]s = the grain table, %[3]s =
// RefSchema (equipments), %[4]d = LIMIT. $1 = window interval.
const dqGrainScanSQL = `
	SELECT e.id_enterprise, r.id_equipment, r.ts_value::timestamptz,
	       r.oee, r.oee_a, r.oee_p, r.oee_q,
	       r.gross, r.net, r.ideal_speed,
	       r.available_time, r.running_time, r.stopped_time,
	       r.planned_downtime, r.downtime, r.changeover_time, r.idle_time
	  FROM %[1]s.%[2]s r
	  JOIN %[3]s.equipments e USING (id_equipment)
	 WHERE r.ts_value >= now() - $1::interval
	 ORDER BY r.ts_value DESC
	 LIMIT %[4]d`

// dqUpsertSQL bulk-upserts a batch of events via unnest arrays. ON CONFLICT on
// the dedup expression index (migration 34) makes re-detection on recompute
// refresh-in-place instead of duplicating. %[1]s = EvSchema (data_quality_event
// lives in the flow schema alongside the runtime tables it observes).
const dqUpsertSQL = `
	INSERT INTO %[1]s.data_quality_event
	    (id_enterprise, id_equipment, grain, bucket_ts, rule, observed_value, severity)
	SELECT * FROM unnest(
	    $1::int[], $2::int[], $3::text[], $4::timestamptz[], $5::text[], $6::float8[], $7::text[])
	ON CONFLICT (id_enterprise, COALESCE(id_equipment, 0), grain, bucket_ts, rule)
	DO UPDATE SET observed_value = EXCLUDED.observed_value,
	              severity       = EXCLUDED.severity,
	              detected_at    = now()`

// RunDQScan scans one destination's recently-computed grain rows, detects
// data-quality violations, and upserts them into data_quality_event. Returns the
// number of events upserted. PURE SIDE-WRITE: it reads runtime rows and writes
// ONLY data_quality_event — it never touches an equipment_runtime_*/agg_* value.
//
// Off unless dqEnabled (config flag DQ_ALARMS_ENABLED) — fully reversible.
func RunDQScan(ctx context.Context, d flows.Dest, dqEnabled bool) (int64, error) {
	if !dqEnabled {
		return 0, nil
	}
	var total int64
	for _, g := range dqGrainMatrix {
		n, err := runDQScanGrain(ctx, d, g)
		if err != nil {
			return total, fmt.Errorf("dq scan %s: %w", g.Grain, err)
		}
		total += n
	}
	return total, nil
}

func runDQScanGrain(ctx context.Context, d flows.Dest, g dqGrainScan) (int64, error) {
	rows, err := d.Pool.Query(ctx,
		fmt.Sprintf(dqGrainScanSQL, d.EvSchema, g.Table, d.RefSchema, dqScanLimit), g.Window)
	if err != nil {
		return 0, fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	var events []DQEvent
	for rows.Next() {
		var m GrainMetrics
		m.Grain = g.Grain
		if err := rows.Scan(
			&m.IDEnterprise, &m.IDEquipment, &m.BucketTS,
			&m.OEE, &m.OeeA, &m.OeeP, &m.OeeQ,
			&m.Gross, &m.Net, &m.IdealSpeed,
			&m.AvailableTime, &m.RunningTime, &m.StoppedTime,
			&m.PlannedDowntime, &m.Downtime, &m.ChangeoverTime, &m.IdleTime,
		); err != nil {
			return 0, fmt.Errorf("scan: %w", err)
		}
		events = append(events, DetectGrain(m)...)
	}
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("rows: %w", err)
	}
	if len(events) == 0 {
		return 0, nil
	}
	return dqUpsert(ctx, d, events)
}

// dqUpsert writes a batch of events with one INSERT ... ON CONFLICT via unnest.
func dqUpsert(ctx context.Context, d flows.Dest, events []DQEvent) (int64, error) {
	n := len(events)
	ent := make([]int32, n)
	eq := make([]int32, n)
	grain := make([]string, n)
	bucket := make([]time.Time, n)
	rule := make([]string, n)
	obs := make([]*float64, n)
	sev := make([]string, n)
	for i, e := range events {
		ent[i] = int32(e.IDEnterprise)
		eq[i] = int32(e.IDEquipment)
		grain[i] = e.Grain
		bucket[i] = e.BucketTS
		rule[i] = string(e.Rule)
		obs[i] = e.ObservedValue
		sev[i] = e.Severity
	}
	tag, err := d.Pool.Exec(ctx, fmt.Sprintf(dqUpsertSQL, d.EvSchema),
		ent, eq, grain, bucket, rule, obs, sev)
	if err != nil {
		return 0, fmt.Errorf("upsert: %w", err)
	}
	return tag.RowsAffected(), nil
}
