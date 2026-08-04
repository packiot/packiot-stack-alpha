// Package deriver is the agent-side DERIVE stage (ADR-0045 P2c): it turns raw
// tags a PLC/tee sends into canonical SparkPlug COUNTS the cloud Calc consumes,
// for two generic, config-driven shapes declared per-equipment in the tenant
// profile (tenantprofile.DerivedRule):
//
//   - INTEGRAL (FLEXO class): a machine with an analog speed but NO production
//     counter. The deriver integrates rate·dt into a monotonic virtual counter.
//   - SUM (PTH class): a machine whose count is split across several registers
//     (A+B). The deriver latches each addend and emits their sum as one count.
//
// It sits in the agent ingest path exactly where DecomposeParameterSuffix sits
// (after decode, before the resolve/allowlist gate). Its Emit suffixes are
// allowlisted via tenantprofile.SynthesizeEquipment, so the synthesized counts
// resolve on the same path as any other tag and reach the SparkPlug session.
//
// Why the agent, not the cloud: the source rates/registers are per-tenant PLC
// quirks; deriving on the agent keeps the cloud edge-transformer + Calc GENERIC
// (they see only canonical counts, ADR-0032 one-ingest-contract). The deriver
// keys on the RAW ARRIVING suffix — the agent ingest does NOT run metric aliases
// inbound (those are register-side) — so a rule's Source/Addends match exactly
// what the tee sends (e.g. "/L5/FLEXO/Status/CurMachSpeed").
//
// Restart safety: the integral accumulator lives in memory and RESETS to zero on
// an agent restart. That is SAFE — the emitted series is an absolute totalizer,
// and the cloud Calc treats prev>cur as a counter reset (incr=cur), never a
// double-count (calc_production_counters/calc.go:276-280).
package deriver

import (
	"math"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tenantprofile"
)

// Deriver holds the compiled derive rules + their running state. It is NOT
// safe for concurrent use — the agent ingest is single-writer per envelope
// (both front-doors funnel through one ingest closure).
type Deriver struct {
	integrals []*integralState
	sums      []*sumState

	// integralBySource routes an arriving suffix to its integral rule.
	integralBySource map[string]*integralState
	// sumByAddend routes an arriving addend suffix to the sum rules that latch it
	// (a suffix could feed more than one rule, so it is a slice).
	sumByAddend map[string][]*sumState
	// isAddend is the fast membership set the ingest uses to decide which arriving
	// suffixes to DROP (they are folded into a sum, never republished raw).
	isAddend map[string]bool
}

type integralState struct {
	source     string
	conversion float64
	clampMin   float64
	maxRate    float64
	emit       []string
	typ        string

	lastTs int64
	accum  float64
	seeded bool
}

type sumState struct {
	addends []string
	emit    []string
	typ     string

	latest map[string]float64
	seen   map[string]bool
}

// New compiles a Deriver from a tenant profile's Derived rules. A nil profile or
// one with no derived rules yields an empty Deriver whose Process is a no-op —
// so building it unconditionally is safe (a tenant without derive rules pays
// nothing). The profile's rules are assumed already validated (LoadProfile /
// GenerateProfile run Profile.Validate).
func New(prof *tenantprofile.Profile) *Deriver {
	dv := &Deriver{
		integralBySource: map[string]*integralState{},
		sumByAddend:      map[string][]*sumState{},
		isAddend:         map[string]bool{},
	}
	if prof == nil {
		return dv
	}
	for _, r := range prof.Derived {
		switch {
		case r.Integral != nil:
			st := &integralState{
				source:     r.Integral.Source,
				conversion: r.Integral.Conversion,
				clampMin:   r.Integral.ClampMin,
				maxRate:    r.Integral.MaxRate,
				emit:       append([]string(nil), r.Emit...),
				typ:        r.Type,
			}
			dv.integrals = append(dv.integrals, st)
			dv.integralBySource[st.source] = st
		case r.Sum != nil:
			st := &sumState{
				addends: append([]string(nil), r.Sum.Addends...),
				emit:    append([]string(nil), r.Emit...),
				typ:     r.Type,
				latest:  map[string]float64{},
				seen:    map[string]bool{},
			}
			dv.sums = append(dv.sums, st)
			for _, a := range st.addends {
				dv.sumByAddend[a] = append(dv.sumByAddend[a], st)
				dv.isAddend[a] = true
			}
		}
	}
	return dv
}

// Empty reports whether the deriver has no rules (a no-op). Callers may skip the
// Process call entirely on an empty deriver.
func (d *Deriver) Empty() bool {
	return len(d.integrals) == 0 && len(d.sums) == 0
}

// Process runs the derive stage over one envelope's decoded tags. It returns:
//   - synth: the synthesized canonical count tags to inject into the ingest path
//     (they resolve + store on the same path as any tag — their Emit suffixes are
//     allowlisted via SynthesizeEquipment).
//   - consumed: the set of arriving suffixes the caller must DROP from the raw
//     passthrough (sum addends — republishing them would look like a totalizer
//     drop to Calc). Integral sources are NOT consumed (a source may legitimately
//     also be a published metric, e.g. MachSpeed).
//
// consumed is non-nil only when the deriver has sum rules; synth is nil when
// nothing was derived this batch.
func (d *Deriver) Process(tags []rawtag.RawTag) (synth []rawtag.RawTag, consumed map[string]bool) {
	if d.Empty() {
		return nil, nil
	}
	if len(d.isAddend) > 0 {
		consumed = map[string]bool{}
	}
	for _, t := range tags {
		// SUM: latch each addend; emit the sum once every addend has been seen.
		if states, ok := d.sumByAddend[t.Metric]; ok {
			v, num := toFloat(t.Value)
			if consumed != nil {
				consumed[t.Metric] = true // folded into a sum regardless of numeric-ness
			}
			if !num {
				continue // non-numeric addend can't contribute; still consumed (dropped)
			}
			for _, st := range states {
				st.latest[t.Metric] = v
				st.seen[t.Metric] = true
				if !st.warmedUp() {
					continue // partial sum looks like a DROP to Calc — hold until all seen
				}
				sum := st.total()
				for _, leaf := range st.emit {
					synth = append(synth, rawtag.RawTag{
						Metric:   leaf,
						Value:    math.Floor(sum),
						TsMillis: t.TsMillis,
						Quality:  true,
					})
				}
			}
			continue
		}
		// INTEGRAL: integrate rate·dt into a monotonic accumulator.
		if st, ok := d.integralBySource[t.Metric]; ok {
			v, num := toFloat(t.Value)
			if !num {
				continue
			}
			rate := v * st.conversion
			if rate < st.clampMin {
				rate = st.clampMin
			}
			if st.maxRate > 0 && rate > st.maxRate {
				continue // spike guard: skip the sample entirely (lastTs unchanged)
			}
			if !st.seeded {
				st.lastTs = t.TsMillis
				st.seeded = true
				continue // seed sample: establish t0, emit nothing
			}
			dt := float64(t.TsMillis-st.lastTs) / 1000.0
			if dt < 0 {
				dt = 0 // out-of-order sample: never integrate backwards
			}
			st.accum += rate * dt
			st.lastTs = t.TsMillis
			for _, leaf := range st.emit {
				synth = append(synth, rawtag.RawTag{
					Metric:   leaf,
					Value:    math.Floor(st.accum),
					TsMillis: t.TsMillis,
					Quality:  true,
				})
			}
		}
	}
	return synth, consumed
}

// warmedUp reports whether every declared addend has been seen at least once.
func (s *sumState) warmedUp() bool {
	for _, a := range s.addends {
		if !s.seen[a] {
			return false
		}
	}
	return true
}

// total sums the latched addend values.
func (s *sumState) total() float64 {
	var sum float64
	for _, a := range s.addends {
		sum += s.latest[a]
	}
	return sum
}

// toFloat coerces a decoded raw-tag value (float64 | bool | string) to a float.
// Only a JSON number is a valid count/rate source; bool/string/nil return
// (0,false) so the caller skips a non-numeric sample.
func toFloat(v any) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case int64:
		return float64(n), true
	case int:
		return float64(n), true
	default:
		return 0, false
	}
}
