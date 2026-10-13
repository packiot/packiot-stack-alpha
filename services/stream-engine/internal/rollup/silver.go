// silver.go — the ADR-0036 §4 SILVER invariant layer: the durable safety net
// that ENFORCES the domain invariants on the served Gold rows so a FUTURE compute
// regression cannot silently corrupt the served plane.
//
// RELATIONSHIP TO dq.go (the DETECTOR):
//   - dq.go / RunDQScan is a PURE SIDE-WRITE: it DETECTS violations (impossible
//     factors, net>gross, negatives) and RECORDS a data_quality_event, but NEVER
//     alters a served value (instrument-before-remediate).
//   - THIS file / RunSilverClamp is the REMEDIATE half: it CLAMPS out-of-range
//     Gold values to their invariant bound so they never reach a dashboard —
//     and, critically, it is NEVER SILENT: every clamp that actually CHANGES a
//     value is paired with an INVARIANT_CLAMPED_* data_quality_event carrying the
//     metric + observed (pre-clamp) value. A clamp is a visible tripwire, not a
//     cover-up. Post-source-fix (#569 line-differencing + A/P/Q) this should fire
//     on ~0 rows; if it starts firing a lot, that is exactly the signal of a NEW
//     regression, surfaced instead of buried.
//
// THE INVARIANTS ENFORCED TODAY (ADR-0036 §4 as relaxed on 2026-09-29, "store
// what was measured" — see migrations/t-oee-uncapped-data):
//   - 0 ≤ oee_a ≤ 1                     → LEAST(GREATEST(oee_a,0),1). Availability
//     is the ONLY capped factor (running time cannot exceed available time; the
//     *_oee_bounds CHECKs still enforce oee_a ≤ 1).
//   - oee, oee_p, oee_q ≥ 0             → GREATEST(x,0). NOT capped at 1: P > 1
//     means the configured ideal speed is too low, hourly Q > 1 means units in
//     transit between sensors. The data keeps them; the UI decides how to show them.
//   - non-negative counts/durations     → GREATEST(x,0) over clampNegCols. SCRAP is
//     NOT in that set: it is signed (see clampNegCols).
//   - net ≤ gross is NOT enforced: net is never lowered (netGtGross is a constant
//     false in silverPredicates). The condition stays visible through RunDQScan's
//     NET_GT_GROSS detector. INVARIANT_CLAMPED_NET_GT_GROSS is kept as a rule name
//     but no longer fires.
//   - gross and net are never lowered by this pass; only a negative value is
//     raised to 0.
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
// and F3 (packiot_analytics) — the identical dest loop in LoopGrains — so any clamp
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

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
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
	// DQRuleInvariantClampedNetGtGross — RETIRED 2026-09-29. It recorded net being
	// lowered to gross (observed_value = the pre-clamp net, e.g. a 523082-vs-11
	// reset spike). net > gross is no longer clamped (silverPredicates' netGtGross is
	// a constant false), so this rule never fires now; the name is kept for the SQL
	// shape and for historical events. dq.go's NET_GT_GROSS still detects it.
	DQRuleInvariantClampedNetGtGross DQRule = "INVARIANT_CLAMPED_NET_GT_GROSS"
)

// clampNegCols is the non-negative count/duration set clamped on every equipment
// grain (GREATEST(x,0)). SCRAP IS NOT IN IT since 2026-09-29: scrap = gross - net
// is SIGNED — a negative hour is units in transit between the infeed and outfeed
// sensors (a fact), and flooring it inflated scrap over every period. All the
// columns below are present on all five equipment_runtime_* tables (dq.go reads
// them from each; the entity/grain sum-lists write them).
//
// History: until 2026-09-29 scrap WAS in this set, and GREATEST(scrap,0) plus the
// oee_q ≤ 1 clamp acted as the ADR-0036 §4 "net ≤ gross" enforcement. Both are
// gone: net > gross is now stored as measured and only DETECTED (RunDQScan's
// NET_GT_GROSS), never repaired here.
var clampNegCols = []string{
	"gross", "net", "available_time", "running_time", "stopped_time",
	"planned_downtime", "downtime", "changeover_time", "idle_time",
	"idle_starved", "idle_blocked", "ideal_production",
}

// silverFactorCols — the four OEE factors, each clamped per factorClamp (oee_a to
// [0,1], the others to ≥ 0 only) and NULL-PRESERVING: RunUnmetered writes NULL to oee/oee_a/oee_p/oee_q to mark a
// row "not metered", and the clamp must keep that NULL (a NULL is not a violation).
var silverFactorCols = []string{"oee", "oee_a", "oee_p", "oee_q"}

// factorClamp is the in-bounds form of a factor column. Since 2026-09-29 only the
// LOWER bound is enforced (a negative ratio is not a measurement): P > 1 means the
// configured ideal speed is too low and hourly Q > 1 means units in transit — the
// data keeps them and the UI decides how to show them. AVAILABILITY keeps [0,1]
// (running time cannot exceed the available time; *_oee_bounds still enforces it).
func factorClamp(a, c string) string {
	if c == "oee_a" {
		return fmt.Sprintf("LEAST(GREATEST(%s.%s, 0), 1)", a, c)
	}
	return fmt.Sprintf("GREATEST(%s.%s, 0)", a, c)
}

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
//     per factorClamp (NULL excluded → the "not metered" NULL is preserved, never a
//     violation);
//   - negs[i]: the i-th count/duration in clampNegCols (scrap NOT included) is
//     negative;
//   - netGtGross: the constant "false" (net > gross is no longer clamped).
//
// Keying on "differs from the clamped form" makes the pass TRULY IDEMPOTENT: once
// clamped, every term is false — the row is never re-selected. net ≤ gross is NOT
// enforced (oee_q is no longer capped at 1); the raw net>gross condition stays
// visible via RunDQScan's NET_GT_GROSS rule (this pass records ACTUAL clamps only).
func silverPredicates(a string) (factors []string, negs []string, netGtGross string) {
	factors = make([]string, len(silverFactorCols))
	for i, c := range silverFactorCols {
		factors[i] = fmt.Sprintf("(%[1]s.%[2]s IS NOT NULL AND %[1]s.%[2]s <> %[3]s)", a, c, factorClamp(a, c))
	}
	negs = make([]string, len(clampNegCols))
	for i, c := range clampNegCols {
		negs[i] = fmt.Sprintf("%s.%s < 0", a, c)
	}
	// net>gross is NO LONGER clamped (2026-09-29): lowering net to gross threw away
	// real good output (transit within an hour; an undercounting infeed meter over a
	// shift). The predicate stays in the SQL shape as a constant false so the
	// detect/clamp statements keep their structure; RunDQScan's NET_GT_GROSS still
	// DETECTS the condition without changing anything.
	netGtGross = "false"
	return factors, negs, netGtGross
}

// silverWhere ORs every per-metric change test (factors, negatives, net>gross)
// into the clamp/detect WHERE.
func silverWhere(factors, negs []string, netGtGross string) string {
	return strings.Join(append(append(append([]string{}, factors...), negs...), netGtGross), " OR ")
}

// silverDetectSQL upserts one INVARIANT_CLAMPED_* event per (row, changed metric)
// BEFORE the clamp overwrites the value, so observed_value is the pre-clamp value.
// Its `violated` flags are the SAME per-metric change tests the clamp WHERE uses.
// %[1]s=EvSchema (data_quality_event lives in public — genuine, route-dependent),
// %[2]s=grain table, %[3]s=RefSchema (equipments→id_enterprise),
// %[4]s=grain label literal (trusted, static), %[19]s=GoldSchema (the *_oee_* grain
// the detect READS lives in gold post-medallion; #251 — split from EvSchema so the
// public shim can drop). $1 = recency window interval.
func silverDetectSQL(evSchema, table, refSchema, grainLabel, goldSchema string) string {
	fs, negs, netGtGross := silverPredicates("r")
	negAny := strings.Join(negs, " OR ")
	where := silverWhere(fs, negs, netGtGross)
	return fmt.Sprintf(`
	INSERT INTO %[1]s.data_quality_event
	    (id_enterprise, id_equipment, grain, bucket_ts, rule, observed_value, severity)
	SELECT eq.id_enterprise, r.id_equipment, '%[4]s', r.ts_value::timestamptz,
	       v.rule, v.observed, 'error'
	  FROM %[19]s.%[2]s r
	  JOIN %[3]s.equipments eq ON eq.id_equipment = r.id_equipment
	  CROSS JOIN LATERAL (VALUES
	      ('%[5]s'::text, r.oee,   %[11]s),
	      ('%[6]s',       r.oee_a, %[12]s),
	      ('%[7]s',       r.oee_p, %[13]s),
	      ('%[8]s',       r.oee_q, %[14]s),
	      ('%[9]s',       %[10]s,  (%[15]s)),
	      ('%[17]s',      r.net,   (%[18]s))
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
		fs[0], fs[1], fs[2], fs[3], negAny, where,
		DQRuleInvariantClampedNetGtGross, netGtGross, goldSchema)
}

// silverClampSQL clamps every value the invariants would move to its bound. The
// WHERE selects ONLY rows where a clamp changes a value, so on clean data it writes
// zero rows (no-op, byte-identical → parity/identity hold) and RowsAffected == the
// number of rows clamped. NULL factors are preserved by the CASE guard AND by the
// NULL-safe WHERE. %[1]s=GoldSchema (the *_oee_* grain lives in gold post-medallion;
// #251), %[2]s=grain table. $1 = recency window interval.
func silverClampSQL(goldSchema, table string) string {
	fs, negs, netGtGross := silverPredicates("r")
	var sets []string
	for _, c := range silverFactorCols {
		sets = append(sets, fmt.Sprintf("%[1]s = CASE WHEN r.%[1]s IS NULL THEN NULL ELSE %[2]s END", c, factorClamp("r", c)))
	}
	for _, c := range clampNegCols {
		sets = append(sets, fmt.Sprintf("%[1]s = GREATEST(r.%[1]s, 0)", c))
	}
	set := "\n\t       " + strings.Join(sets, ",\n\t       ")
	where := silverWhere(fs, negs, netGtGross)
	return fmt.Sprintf(`
	UPDATE %[1]s.%[2]s r SET%[3]s
	 WHERE r.ts_value >= now() - $1::interval
	   AND (%[4]s)`, goldSchema, table, set, where)
}

// RunSilverClamp enforces the Silver invariants on one destination's recently
// computed Gold rows, pairing every clamp with an INVARIANT_CLAMPED_* event.
// Returns the total number of rows clamped (0 on clean data — the expected
// steady state post-source-fix). Runs only when enabled (SILVER_CLAMP_ENABLED,
// default true).
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
		silverDetectSQL(d.EvSchema, g.Table, d.RefSchema, g.Grain, d.GoldSchema), g.Window); err != nil {
		return 0, fmt.Errorf("detect: %w", err)
	}
	tag, err := tx.Exec(ctx, silverClampSQL(d.GoldSchema, g.Table), g.Window)
	if err != nil {
		return 0, fmt.Errorf("clamp: %w", err)
	}
	return tag.RowsAffected(), tx.Commit(ctx)
}
