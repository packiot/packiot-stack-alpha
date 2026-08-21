// oee.go — the CANONICAL OEE definition (ADR-0048 §Fault-3).
//
// THE PROBLEM (two coexisting definitions). The rollup historically stored a
// TOP-DOWN headline `oee = LEAST(net / ideal_production, 1)` while the served
// components were BOTTOM-UP: oee_a = running/planned, oee_q = net/gross, and
// oee_p a back-solved residual oee/(oee_a·oee_q) clamped to [0,1]. Those two
// are algebraically the SAME quantity when nothing clamps — they telescope:
//
//	A·P·Q = (run/planned)·(gross/(rate·run/60))·(net/gross)
//	      = net / (rate·planned/60) = net / ideal_production          (†)
//
// so `net/ideal_production` IS A·P·Q reduced. They DIVERGE only because (a) each
// factor is independently clamped to [0,1] — when Performance genuinely exceeds
// 1 (a count spike, or an under-counted running_time) the clamp drops the excess
// so A·P·Q < the top-down value; and (b) a zero denominator (gross=0 → Q=0, or
// running=0 → A=0) makes the residual undefined → oee_p=0 while the top-down oee
// is still positive. Live ent-3 audit: 60% of producing shifts had
// |oee − a·p·q| > 0.01 (mean 0.27).
//
// THE DECISION. OEE is DEFINED as the product of three genuine [0,1] factors
// (ISO-22400 / the standard OEE waterfall). The stored `oee` IS that product, so
// oee == oee_a · oee_p · oee_q holds BY CONSTRUCTION, always. Performance is
// computed DIRECTLY (not back-solved): P = gross / (ideal_speed · running/60),
// clamped. The former top-down net/ideal_production becomes a data-quality
// cross-check (dq.go), not a second headline. By (†) this changes NO value on
// clean data (they were equal); it only lowers OEE exactly where a factor was
// clamped — i.e. where the top-down number was silently over-crediting a spike
// or an availability gap. Because it makes the availability factor load-bearing,
// it is gated (OeeCanonicalAPQ) and sequenced AFTER the availability fix.
//
// This file is the SINGLE SOURCE OF THE ALGEBRA: the SQL reconcile passes
// (shiftOeeReconcileSQL / hourOeeReconcileSQL) mirror CanonicalOEE exactly, and
// oee_test.go proves the identity + spike-bounding on synthetic rows without a
// database (the golden SQL tests need Postgres + the `golden` build tag).
package rollup

// Clamp01 bounds a ratio to the OEE factor domain [0,1]. A NaN/Inf-free helper:
// callers pass already-finite values (the SQL uses NULLIF to avoid div-by-zero,
// mirrored here by the zero-denominator guards in the factor helpers).
func Clamp01(x float64) float64 {
	if x < 0 {
		return 0
	}
	if x > 1 {
		return 1
	}
	return x
}

// AvailabilityFactor = running / planned-production-time, clamped. planned is
// available_time (shift/hour elapsed minus planned downtime). A zero planned
// window yields 0 (nothing to be available for).
func AvailabilityFactor(runningSec, plannedSec float64) float64 {
	if plannedSec <= 0 {
		return 0
	}
	return Clamp01(runningSec / plannedSec)
}

// QualityFactor = good/total = net/gross, clamped. Zero gross yields 0.
func QualityFactor(net, gross float64) float64 {
	if gross <= 0 {
		return 0
	}
	return Clamp01(net / gross)
}

// PerformanceFactor = actual output / theoretical-at-ideal during running =
// gross / (idealSpeedPerMin · running/60), clamped. This is the DIRECT
// definition (not the back-solved residual). A zero rate or zero running window
// yields 0 (no theoretical basis → no performance credit). Using GROSS (total
// count) here is what makes A·P·Q telescope to net/ideal_production — see (†).
func PerformanceFactor(gross, idealSpeedPerMin, runningSec float64) float64 {
	theoretical := idealSpeedPerMin * runningSec / 60.0
	if theoretical <= 0 {
		return 0
	}
	return Clamp01(gross / theoretical)
}

// CanonicalOEE returns the three bounded factors and their product — the stored
// OEE waterfall. oee == a·p·q by construction. This is the exact algebra the SQL
// reconcile pass applies to every gold row when OeeCanonicalAPQ is engaged.
func CanonicalOEE(net, gross, runningSec, plannedSec, idealSpeedPerMin float64) (oee, a, p, q float64) {
	a = AvailabilityFactor(runningSec, plannedSec)
	q = QualityFactor(net, gross)
	p = PerformanceFactor(gross, idealSpeedPerMin, runningSec)
	oee = a * p * q
	return oee, a, p, q
}
