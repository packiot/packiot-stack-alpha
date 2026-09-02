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

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
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

	// spikeFloor is the rate-INDEPENDENT backstop for the ADR-0045 P1 first-boot
	// spike: when an increment consumes the ENTIRE absolute totalizer
	// (value >= absolute) and that totalizer is >= spikeFloor, the upstream
	// differenced cur−0 on a missing/reset baseline — a physically-impossible
	// "whole totalizer as one increment". This catch fires even when no rated
	// speed is configured (the counters-only LINE-LEAD path, where the rate·Δt
	// bound fails open) and on the first sample after a worker restart (empty Δt
	// cache), the two holes the rate·Δt bound alone leaves open. The floor keeps
	// a genuinely-small totalizer (a legit reset that ticked up a few parts,
	// where value==absolute is benign) from being clamped.
	spikeFloor float64

	mu   sync.Mutex
	last map[clampKey]int64 // stream → last sample ts (unix ms)
}

// eval applies the clamp to one counter increment. It returns the value to
// actually write (unchanged, or 0 when clamped) and — only when it clamped —
// a ClampEvent for the caller to record. ratePerMin is the equipment's
// configured rated speed (equipments.production_speed, units/min); a
// non-positive rate fails the clamp open for this stream.
func (c *incrementClamp) eval(eq, enterprise int, kind sparkplug.MetricKind, tsMs int64, ratePerMin, value, absolute float64) (float64, *ClampEvent) {
	key := clampKey{eq, kind}

	// Only positive increments can be phantom over-counts; 0/negative are
	// upstream reset artifacts and pass untouched. Still advance the clock so
	// the next positive sample has a Δt.
	if value <= 0 {
		c.observe(key, tsMs)
		return value, nil
	}

	// ── Delta-from-zero spike catch (rate-independent, first-sample-proof) ──
	// The ADR-0045 P1 first-boot signature: the increment equals/exceeds the
	// whole absolute totalizer because the upstream differenced cur−0 on a
	// missing/reset baseline (*_incr == *_val). In steady state a delta is a
	// tiny fraction of the cumulative, so value >= absolute >= spikeFloor is
	// never real production. Checked BEFORE the rate·Δt path so it also guards
	// the counters-only LINE-LEAD path (ratePerMin==0 → fails open below) and
	// the first sample after a worker restart (no Δt yet → fails open below).
	if c.spikeFloor > 0 && absolute >= c.spikeFloor && value >= absolute {
		c.observe(key, tsMs)
		if c.logger != nil {
			c.logger.Warn("increment sanity clamp REJECTED delta-from-zero spike (increment ≈ absolute totalizer)",
				slog.Int("id_equipment", eq),
				slog.String("kind", kind.String()),
				slog.Float64("observed", value),
				slog.Float64("absolute", absolute),
				slog.Float64("spike_floor", c.spikeFloor),
			)
		}
		return 0, &ClampEvent{
			IDEnterprise: enterprise,
			IDEquipment:  eq,
			Kind:         kind,
			BucketTS:     time.UnixMilli(tsMs).Truncate(time.Second).UTC(),
			Observed:     value,
			Bound:        c.spikeFloor,
		}
	}

	// The rate·Δt bound needs a configured rated speed; without one, fail open
	// (the spike catch above is the only defense for rate-less streams).
	if ratePerMin <= 0 {
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

// evalSpeed decides whether a DERIVED speed sample (equipment_values.speed,
// the decode Phase-6 computeSpeed = incr·60000/Δt, units/min) must be voided
// before it reaches the UPSERT. Two arms, both physically grounded in the same
// K·rate invariant the count clamp uses:
//
//   - LOCKSTEP (countClamped): the speed was derived from the very increment
//     the count clamp just rejected as a glitch/spike this sample — the same
//     delta produced both, so a rejected count means an untrustworthy speed.
//     Void it regardless of rate (this is the ONLY arm for rate-less streams,
//     mirroring the count clamp's fail-open-without-a-rate posture).
//   - RATE BOUND: even when the count was NOT clamped (e.g. the fail-open first
//     sample after a worker restart, or the ADR-0049 no-speed-guard fallback
//     letting a tiny-Δt division through), a speed above K·rate is not a
//     physically possible machine speed — a machine rated ratePerMin parts/min
//     cannot momentarily run thousands of times faster. Reuse the clamp's k so
//     the speed bound tracks the count bound. A non-positive rate skips this
//     arm (fail-open) — a rate·0 bound would wrongly reject every real speed.
//
// Returns reject=true (with the bound it exceeded, 0 for the lockstep arm) when
// the speed must be dropped; the caller writes NULL so the UPSERT's
// COALESCE(EXCLUDED.speed, existing) carries the prior good speed forward.
func (c *incrementClamp) evalSpeed(countClamped bool, ratePerMin, speed float64) (reject bool, bound float64) {
	if countClamped {
		return true, 0
	}
	if ratePerMin <= 0 || speed <= 0 {
		return false, 0
	}
	bound = c.k * ratePerMin
	if speed > bound {
		return true, bound
	}
	return false, 0
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
