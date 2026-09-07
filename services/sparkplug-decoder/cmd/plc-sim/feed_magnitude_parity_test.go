package main

import "testing"

// ─────────────────────────────────────────────────────────────────────────────
// PER-LINE FEED-MAGNITUDE PARITY GUARD (#77)
//
// Each simulated LINE (Unit=="") drives its tp=3 line equipment through its OWN
// Sparkplug counter stream. That stream's rate — the `line.MachSpeed` field,
// units/min accumulated while StateCurrent==6 — is the sim's line "feed
// magnitude". If it drifts from prod's real line throughput, line-vs-prod gross
// diverges. #18 first caught such a drift by a MANUAL line-vs-prod audit; #491
// then shipped the L5/L3/L4 line entries with the leftover self-ref-idx numbers
// (105/88/92) sitting in the MachSpeed field instead of a calibrated speed,
// under-feeding those lines ~29–37% vs prod — and nothing flagged it until a
// second manual audit.
//
// This guard turns that manual audit into a CI gate. It pins every line's feed
// magnitude to a prod-calibrated band and, crucially, FAILS when a new line is
// added without a band — forcing calibration at the point a line is introduced,
// which is exactly where #491 slipped through.
// ─────────────────────────────────────────────────────────────────────────────

// prodLineFeed is prod's calibrated throughput for one line, used as the center
// of that line's acceptable feed-magnitude band.
//
// Source (SELECT-only, prod packiot40, 2026-07-18): `expected` = the tp=3 line
// equipment's `equipments.production_speed` — the factory's configured nominal
// line speed. It is the stable, re-runnable anchor (a config column, not a
// noisy runtime series). Cross-checked against the 21-day median full-shift
// gross/running-minute, which sits a few % under nominal as real lines do:
//
//	line  prod eq  production_speed  measured median gross/run-min (21d)
//	L8    218      120               114.6
//	L5    60       147                62.4  (prod L5 itself erratic: p25 0.01 / p75 155)
//	L3    75       140               134.0
//	L4    83       147               143.8
//
// To re-calibrate, run against prod (SELECT-only):
//
//	SELECT e.id_equipment, e.cd_equipment, e.production_speed
//	FROM equipments e
//	JOIN packml_register pr ON pr.id_equipment = e.id_equipment AND pr.id_unit IS NULL
//	WHERE pr.packml_topic IN ('C-PACK/SC/LINHAS/L8','C-PACK/SC/LINHAS/L5',
//	                          'C-PACK/SC/LINHAS/L3','C-PACK/SC/LINHAS/L4')
//	  AND e.id_enterprise = 1;
type prodLineFeed struct {
	expected float64 // prod production_speed, units/min
}

var prodLineFeeds = map[string]prodLineFeed{
	"L8": {expected: 120},
	"L5": {expected: 147},
	"L3": {expected: 140},
	"L4": {expected: 147},
}

// feedMagnitudeTolerance is the ± band a line's sim MachSpeed may occupy around
// prod's configured speed. Wide enough to absorb the real gap between prod's
// nominal config and its measured running rate (~2–7% under) plus deliberate
// minor tuning; tight enough to catch the ~29–37% under-feeds #77 found. A drift
// this size is never intentional — it means a feed was left uncalibrated.
const feedMagnitudeTolerance = 0.15

// TestLineFeedMagnitudeParity pins each simulated line's own-stream feed rate to
// its prod-calibrated band. See the header comment for why this exists.
func TestLineFeedMagnitudeParity(t *testing.T) {
	seen := map[string]bool{}
	for _, l := range lines {
		if l.Unit != "" {
			continue // members feed member eqs, not the line's own-stream
		}
		if seen[l.Line] {
			t.Errorf("duplicate line entry for %s (Unit==\"\") — a line must have exactly one own-stream", l.Line)
		}
		seen[l.Line] = true

		want, ok := prodLineFeeds[l.Line]
		if !ok {
			t.Errorf("line %s has NO prod-calibrated feed band. Add its prod "+
				"production_speed to prodLineFeeds (SELECT-only, see header) before "+
				"shipping — an uncalibrated feed under/over-counts vs prod (the #77/#491 class).",
				l.Line)
			continue
		}

		lo := want.expected * (1 - feedMagnitudeTolerance)
		hi := want.expected * (1 + feedMagnitudeTolerance)
		if l.MachSpeed < lo || l.MachSpeed > hi {
			drift := (l.MachSpeed/want.expected - 1) * 100
			t.Errorf("line %s feed magnitude MachSpeed=%.0f drifts %+.1f%% from prod "+
				"production_speed=%.0f (allowed band [%.1f, %.1f], tol ±%.0f%%). Recalibrate "+
				"the own-stream feed to prod or line-vs-prod gross will diverge.",
				l.Line, l.MachSpeed, drift, want.expected, lo, hi, feedMagnitudeTolerance*100)
		}
	}

	// Reciprocal guard: every calibrated band must map to a live line entry, so a
	// renamed/removed line doesn't leave a stale calibration silently unused.
	for name := range prodLineFeeds {
		if !seen[name] {
			t.Errorf("prodLineFeeds has a band for %q but no line entry (Unit==\"\") uses it — "+
				"stale calibration; remove it or restore the line.", name)
		}
	}
}
