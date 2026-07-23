// silver.go — the ADR-0036 §4 SILVER invariant layer: the durable safety net
// that ENFORCES the domain invariants on the served Gold rows so a FUTURE compute
// regression cannot silently corrupt the served plane.
//
// RELATIONSHIP TO dq.go (the DETECTOR):
//   - dq.go / RunDQScan is a PURE SIDE-WRITE: it DETECTS violations (oee>1,
//     net>gross, negatives) and RECORDS a data_quality_event, but NEVER alters a
//     served value (instrument-before-remediate).
//   - THIS file / RunSilverClamp is the REMEDIATE half: it CLAMPS out-of-range
//     Gold values to their invariant bound so they never reach a dashboard —
//     and, critically, it is NEVER SILENT: every clamp that actually CHANGES a
//     value is paired with an INVARIANT_CLAMPED_* data_quality_event carrying the
//     metric + observed (pre-clamp) value. A clamp is a visible tripwire, not a
//     cover-up. Post-source-fix (#569 line-differencing + A/P/Q) this should fire
//     on ~0 rows; if it starts firing a lot, that is exactly the signal of a NEW
//     regression, surfaced instead of buried.
//
// THE INVARIANTS (ADR-0036 §4):
//   - 0 ≤ oee, oee_a, oee_p, oee_q ≤ 1  → LEAST(GREATEST(x,0),1).
//   - net ≤ gross                       → scrap = GREATEST(gross-net,0); oee_q,
//     being net/gross, is caught by the [0,1] clamp above. gross/net themselves
//     are NOT lowered (that would move the comparator's compared columns) — the
//     violation is surfaced via oee_q's clamp + the NET_GT_GROSS event.
//   - non-negative counts/durations     → GREATEST(x,0).
//   - Performance capped at a sane bound → oee_p (today the residual
//     oee/(oee_a·oee_q), which is UNBOUNDED when oee_a·oee_q is tiny) is bounded
//     to ≤1 by the [0,1] clamp, with the pre-clamp residual exposed in the event.
//
// WHY A SEPARATE PASS (not inline in each rollup UPDATE):
//   - ONE home for the invariant contract (ADR-0036 §4: "Silver is a named layer
//     with a single invariant contract") — the same discipline dq.go follows.
//   - The rollup value/event SQL is left BYTE-UNCHANGED, so every existing
//     `-tags golden` expectation stays byte-identical (it sidesteps the
//     golden-fixture churn the #569/Defect-B/T0-2 changes each hit). Only this
//     file's own new golden fixture exercises the clamp path.
//   - The clamp is IDEMPOTENT and SELF-LIMITING: the UPDATE's WHERE selects only
//     genuine violators, so a clamped row is in-bounds on the next tick and is not
//     re-selected — and a clean tick writes ZERO rows (a true no-op).
//
// COMPARATOR SAFETY (verified): RunSilverClamp runs for BOTH F2 (shadow_go_port)
// and F3 (packiot_shadow) — the identical dest loop in LoopGrains — so any clamp
// applies to both flows identically. The bake F2↔F3 identity fingerprints only
// count / sum(gross) / sum(running_time); this pass never lowers gross/net and
// only touches running_time on already-negative data, and clamps both flows the
// same way → the identity holds in every case (byte-identical when clean). F1
// (legacy `public`) is never in flows.Standard, so it is never clamped; the
// F1↔F2 fidelity check is tolerance-banded on gross/running_time only.
package rollup

import (
	"context"
	"fmt"
	"strings"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

// INVARIANT_CLAMPED rule family (data_quality_event.rule). One rule per clamped
// metric so the dedup index (id_enterprise, id_equipment, grain, bucket_ts, rule)
// keeps one live event per (row, metric) rather than collapsing all clamps on a
// row into one. observed_value carries the PRE-clamp value; the clamped value is
// the invariant bound the rule names (0/1 for factors, 0 for negatives).
const (
	DQRuleInvariantClampedOEE      DQRule = "INVARIANT_CLAMPED_OEE"
	DQRuleInvariantClampedOEEA     DQRule = "INVARIANT_CLAMPED_OEE_A"
	DQRuleInvariantClampedOEEP     DQRule = "INVARIANT_CLAMPED_OEE_P"
	DQRuleInvariantClampedOEEQ     DQRule = "INVARIANT_CLAMPED_OEE_Q"
	DQRuleInvariantClampedNegative DQRule = "INVARIANT_CLAMPED_NEGATIVE"
)

// clampNegCols is the non-negative count/duration set clamped on every equipment
// grain (GREATEST(x,0)). All are present on all five equipment_runtime_* tables
// (dq.go reads them from each; the entity/grain sum-lists write them).
//
// `scrap` is IN this set (a non-negative count), NOT enforced as scrap==gross-net.
// WHY: at the shift/hour grains scrap IS gross-net, so GREATEST(scrap,0) already
// yields GREATEST(gross-net,0) when net>gross — the ADR-0036 §4 "net≤gross via
// scrap" enforcement. But at the DAY/WEEK/MONTH grains scrap is SUMMED from
// children (Σ max(child.gross-child.net,0)), which legitimately EXCEEDS
// GREATEST(Σgross-Σnet,0) — so forcing scrap=gross-net there would corrupt correct
// aggregate scrap (a live F3 check found 20 week + 34 day + 8 month such rows with
// NON-negative scrap that are NOT violations). Treating scrap as a plain
// non-negative column is the correct, grain-uniform generalization; net≤gross is
// still enforced by the oee_q [0,1] clamp (oee_q=net/gross capped at 1) and the
// raw net>gross condition stays visible via RunDQScan's NET_GT_GROSS detector.
var clampNegCols = []string{
	"gross", "net", "scrap", "available_time", "running_time", "stopped_time",
	"planned_downtime", "downtime", "changeover_time", "idle_time",
	"idle_starved", "idle_blocked", "ideal_production",
}

// silverFactorCols — the four OEE factors, each bounded to [0,1] and
// NULL-PRESERVING: RunUnmetered writes NULL to oee/oee_a/oee_p/oee_q to mark a
// row "not metered", and the clamp must keep that NULL (a NULL is not a violation).
var silverFactorCols = []string{"oee", "oee_a", "oee_p", "oee_q"}

// factorClamp is the in-bounds form of a factor column: LEAST(GREATEST(x,0),1).
func factorClamp(a, c string) string { return fmt.Sprintf("LEAST(GREATEST(%s.%s, 0), 1)", a, c) }

// silverNegLeast is LEAST over the non-negative set — the most-negative observed
// value recorded on the NEGATIVE event (mirrors dq.go's minNeg semantics).
func silverNegLeast(a string) string {
	out := make([]string, len(clampNegCols))
	for i, c := range clampNegCols {
		out[i] = a + "." + c
	}
	return "LEAST(" + strings.Join(out, ", ") + ")"
}

// silverPredicates returns, for alias a and using the "the clamp would CHANGE this
// value" test (NOT "raw out of range"), the per-metric change predicates that are
// the SINGLE SOURCE OF TRUTH shared by the detector and the clamp UPDATE — so an
// event fires exactly when, and only when, a clamp changes a value:
//   - factors[i]: the i-th OEE factor is non-null AND differs from its clamped form
//     (NULL excluded → the "not metered" NULL is preserved, never a violation);
//   - negs[i]: the i-th count/duration (scrap included) is negative.
//
// Keying on "differs from the clamped form" makes the pass TRULY IDEMPOTENT: once
// clamped, every term is false — the row is never re-selected. net≤gross is
// enforced through the oee_q [0,1] clamp (oee_q=net/gross capped at 1); the raw
// net>gross condition stays visible via RunDQScan's NET_GT_GROSS rule (this pass
// records ACTUAL clamps only).
func silverPredicates(a string) (factors []string, negs []string) {
	factors = make([]string, len(silverFactorCols))
	for i, c := range silverFactorCols {
		factors[i] = fmt.Sprintf("(%[1]s.%[2]s IS NOT NULL AND %[1]s.%[2]s <> %[3]s)", a, c, factorClamp(a, c))
	}
	negs = make([]string, len(clampNegCols))
	for i, c := range clampNegCols {
		negs[i] = fmt.Sprintf("%s.%s < 0", a, c)
	}
	return factors, negs
}

// silverWhere ORs every per-metric change test into the clamp/detect WHERE.
func silverWhere(factors, negs []string) string {
	return strings.Join(append(append([]string{}, factors...), negs...), " OR ")
}

// silverDetectSQL upserts one INVARIANT_CLAMPED_* event per (row, changed metric)
// BEFORE the clamp overwrites the value, so observed_value is the pre-clamp value.
// Its `violated` flags are the SAME per-metric change tests the clamp WHERE uses.
// %[1]s=EvSchema, %[2]s=grain table, %[3]s=RefSchema (equipments→id_enterprise),
// %[4]s=grain label literal (trusted, static). $1 = recency window interval.
func silverDetectSQL(evSchema, table, refSchema, grainLabel string) string {
	fs, negs := silverPredicates("r")
	negAny := strings.Join(negs, " OR ")
	where := silverWhere(fs, negs)
	return fmt.Sprintf(`
	INSERT INTO %[1]s.data_quality_event
	    (id_enterprise, id_equipment, grain, bucket_ts, rule, observed_value, severity)
	SELECT eq.id_enterprise, r.id_equipment, '%[4]s', r.ts_value::timestamptz,
	       v.rule, v.observed, 'error'
	  FROM %[1]s.%[2]s r
	  JOIN %[3]s.equipments eq ON eq.id_equipment = r.id_equipment
	  CROSS JOIN LATERAL (VALUES
	      ('%[5]s'::text, r.oee,   %[11]s),
	      ('%[6]s',       r.oee_a, %[12]s),
	      ('%[7]s',       r.oee_p, %[13]s),
	      ('%[8]s',       r.oee_q, %[14]s),
	      ('%[9]s',       %[10]s,  (%[15]s))
	  ) AS v(rule, observed, violated)
	 WHERE r.ts_value >= now() - $1::interval
	   AND (%[16]s)
	   AND v.violated
	ON CONFLICT (id_enterprise, COALESCE(id_equipment, 0), grain, bucket_ts, rule)
	DO UPDATE SET observed_value = EXCLUDED.observed_value,
	              severity       = EXCLUDED.severity,
	              detected_at     = now()`,
		evSchema, table, refSchema, grainLabel,
		DQRuleInvariantClampedOEE, DQRuleInvariantClampedOEEA, DQRuleInvariantClampedOEEP,
		DQRuleInvariantClampedOEEQ, DQRuleInvariantClampedNegative,
		silverNegLeast("r"),
		fs[0], fs[1], fs[2], fs[3], negAny, where)
}

// silverClampSQL clamps every value the invariants would move to its bound. The
// WHERE selects ONLY rows where a clamp changes a value, so on clean data it writes
// zero rows (no-op, byte-identical → parity/identity hold) and RowsAffected == the
// number of rows clamped. NULL factors are preserved by the CASE guard AND by the
// NULL-safe WHERE. %[1]s=EvSchema, %[2]s=grain table. $1 = recency window interval.
func silverClampSQL(evSchema, table string) string {
	fs, negs := silverPredicates("r")
	var sets []string
	for _, c := range silverFactorCols {
		sets = append(sets, fmt.Sprintf("%[1]s = CASE WHEN r.%[1]s IS NULL THEN NULL ELSE %[2]s END", c, factorClamp("r", c)))
	}
	for _, c := range clampNegCols {
		sets = append(sets, fmt.Sprintf("%[1]s = GREATEST(r.%[1]s, 0)", c))
	}
	set := "\n\t       " + strings.Join(sets, ",\n\t       ")
	where := silverWhere(fs, negs)
	return fmt.Sprintf(`
	UPDATE %[1]s.%[2]s r SET%[3]s
	 WHERE r.ts_value >= now() - $1::interval
	   AND (%[4]s)`, evSchema, table, set, where)
}

// RunSilverClamp enforces the Silver invariants on one destination's recently
// computed Gold rows, pairing every clamp with an INVARIANT_CLAMPED_* event.
// Returns the total number of rows clamped (0 on clean data — the expected
// steady state post-source-fix). Off unless enabled (SILVER_CLAMP_ENABLED).
//
// Per grain the detect+clamp run in ONE transaction so the pairing is atomic
// (never a clamp without its event, never an event without the clamp committing),
// and take the same non-blocking per-dest runtime advisory lock the rollups use
// so the clamp never deadlocks with runtime-provision (skip-and-retry if held).
func RunSilverClamp(ctx context.Context, d flows.Dest, enabled bool) (int64, error) {
	if !enabled {
		return 0, nil
	}
	var total int64
	for _, g := range dqGrainMatrix {
		n, err := runSilverClampGrain(ctx, d, g)
		if err != nil {
			return total, fmt.Errorf("silver clamp %s: %w", g.Grain, err)
		}
		total += n
	}
	return total, nil
}

func runSilverClampGrain(ctx context.Context, d flows.Dest, g dqGrainScan) (int64, error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	if got, err := tryRuntimeLock(ctx, tx, d.Name); err != nil {
		return 0, fmt.Errorf("advisory try-lock: %w", err)
	} else if !got {
		return 0, tx.Commit(ctx) // provision holds it — retry next tick
	}
	// DETECT first (reads pre-clamp values → observed_value), THEN clamp. Same tx.
	if _, err := tx.Exec(ctx,
		silverDetectSQL(d.EvSchema, g.Table, d.RefSchema, g.Grain), g.Window); err != nil {
		return 0, fmt.Errorf("detect: %w", err)
	}
	tag, err := tx.Exec(ctx, silverClampSQL(d.EvSchema, g.Table), g.Window)
	if err != nil {
		return 0, fmt.Errorf("clamp: %w", err)
	}
	return tag.RowsAffected(), tx.Commit(ctx)
}
