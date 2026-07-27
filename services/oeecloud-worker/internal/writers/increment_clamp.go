// increment_clamp.go — the per-equipment production-increment SANITY CLAMP
// (ADR-0037 Silver invariant, flag-gated INCREMENT_SANITY_CLAMP_ENABLED).
//
// PROBLEM. equipment_values.net_production_incr / gross_production_incr /
// scrap_incr are DELTAS the upstream Calc differences from a per-topic
// baseline. When a single Sparkplug counter topic is fed by TWO publishers
// with different totalizer origins (e.g. plc-sim's ≈1.9k vs a real agent's
// ≈830k absolute), every publisher switch mints a PHANTOM increment ≈ the gap
// (≈828k). The continuous-aggregate then SUMs that phantom into the served
// OEE, corrupting it (masked to oee=1.0 by the downstream Silver clamp).
//
// INVARIANT. A machine running at its CONFIGURED rated speed can produce at
// most rated_speed · Δt parts between two readings. Any increment above
// K · rated_speed · Δt is therefore not physically possible production — it is
// a baseline/reorder/double-source artifact. We reject it (emit 0) BEFORE it
// reaches the equipment_values UPSERT, i.e. before the cagg SUM, and surface a
// ClampEvent so the rejection is observable (a data_quality_event), never
// silent.
//
// This is defense-in-depth: it protects EVERY equipment (not just eq 57)
// against future double-source / reordered-sample phantoms, using the same
// equipments.production_speed the rollup already trusts as ideal_speed.
package writers

import (
	"log/slog"
	"sync"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/sparkplug"
)

// ClampEvent records ONE production increment the clamp rejected. It is
// surfaced from EquipmentValues.Build so the handler can side-write a
// data_quality_event (rule INVARIANT_CLAMPED_INCREMENT). Observability only —
// it never gates the ingest write (the value is already zeroed in the UPSERT).
type ClampEvent struct {
	IDEnterprise int
	IDEquipment  int
	Kind         sparkplug.MetricKind
	BucketTS     time.Time // sample ts truncated to the second (== ts_value)
	Observed     float64   // the original (rejected) increment
	Bound        float64   // the plausible-max bound it exceeded
}

// clampKey identifies one production-counter STREAM (per equipment, per
// counter kind). Processed / Consumed / Defective for the same equipment
// arrive as separate metrics at the same ts, so each needs its own Δt cadence
// — otherwise the first would steal the others' "time since last reading".
type clampKey struct {
	eq   int
	kind sparkplug.MetricKind
}

// incrementClamp holds the clamp config + per-stream last-sample clock. Δt is
// measured in-process from the last sample seen on each stream and floored at
// minDt so a sub-interval burst can't collapse the bound to near zero and
// false-positive a legitimate count. Every uncertainty is FAIL-OPEN (first
// sample, out-of-order, absent rated speed): the clamp fires only on a
// positive, above-bound increment. A cold cache or restart therefore lets at
// most one phantom per stream slip through before the clamp re-arms on the
// next sample — and the phantom is continuous, so it is re-caught immediately.
type incrementClamp struct {
	k      float64
	minDt  time.Duration
	logger *slog.Logger

	mu   sync.Mutex
	last map[clampKey]int64 // stream → last sample ts (unix ms)
}

// eval applies the clamp to one counter increment. It returns the value to
// actually write (unchanged, or 0 when clamped) and — only when it clamped —
// a ClampEvent for the caller to record. ratePerMin is the equipment's
// configured rated speed (equipments.production_speed, units/min); a
// non-positive rate fails the clamp open for this stream.
func (c *incrementClamp) eval(eq, enterprise int, kind sparkplug.MetricKind, tsMs int64, ratePerMin, value float64) (float64, *ClampEvent) {
	key := clampKey{eq, kind}

	// Only positive increments can be phantom over-counts; 0/negative are
	// upstream reset artifacts and pass untouched. Still advance the clock so
	// the next positive sample has a Δt.
	if value <= 0 || ratePerMin <= 0 {
		c.observe(key, tsMs)
		return value, nil
	}

	last, had := c.observe(key, tsMs)
	if !had {
		return value, nil // first sample on this stream — no Δt yet
	}
	dtMs := tsMs - last
	if dtMs <= 0 {
		return value, nil // out-of-order / same-ms — can't bound, fail-open
	}
	if floor := c.minDt.Milliseconds(); dtMs < floor {
		dtMs = floor // floor Δt so a burst can't shrink the bound
	}

	bound := c.k * ratePerMin * (float64(dtMs) / 60000.0)
	if value <= bound {
		return value, nil
	}

	if c.logger != nil {
		c.logger.Warn("increment sanity clamp REJECTED implausible production increment",
			slog.Int("id_equipment", eq),
			slog.String("kind", kind.String()),
			slog.Float64("observed", value),
			slog.Float64("bound", bound),
			slog.Float64("rate_per_min", ratePerMin),
		)
	}
	return 0, &ClampEvent{
		IDEnterprise: enterprise,
		IDEquipment:  eq,
		Kind:         kind,
		BucketTS:     time.UnixMilli(tsMs).Truncate(time.Second).UTC(),
		Observed:     value,
		Bound:        bound,
	}
}

// observe records tsMs as the stream's latest sample time and returns the
// PRIOR timestamp (and whether one existed). Monotone: an out-of-order (older)
// sample never rewinds the clock.
func (c *incrementClamp) observe(key clampKey, tsMs int64) (prev int64, had bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	prev, had = c.last[key]
	if !had || tsMs > prev {
		c.last[key] = tsMs
	}
	return prev, had
}
