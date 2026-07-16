// sentinel.go — the F2/F3 identity + int-overflow SENTINEL that runs as a
// deploy-time CI gate (cmd/oeecloud-worker --identity-sentinel), turning the
// continuous in-process bake (RunIdentityTick, which only moves a Prometheus
// gauge) into a hard pass/fail a deploy run can go red on.
//
// WHY A ONE-SHOT GATE ON TOP OF THE LIVE LOOP:
//   - RunIdentityTick fingerprints each surface as a SINGLE whole-window
//     aggregate. That is cheap and good for a trend gauge, but a whole-surface
//     sum can MASK a compensating per-line divergence (line A +1000, line B
//     -1000 nets to zero). A deploy gate must be adversarial, so the sentinel
//     compares per NATURAL KEY (nm_equipment|tp_equipment), catching a single
//     line that flips while the surface total stays put.
//   - The gauge is only actionable if someone is watching Grafana. A CI gate is
//     a LOUD, AUTOMATIC signal wired to the deploy exit code.
//
// THREE THINGS IT ASSERTS (all SELECT-only, both DBs):
//  1. Determinism (F2==F3) per natural key on the DERIVED OEE grains
//     (equipment_runtime_shift, production_orders_runtime) — count-exact, sums
//     within identityTol, running_time byte-exact, via the SAME IdentityMatch
//     the live loop uses.
//  2. Determinism (F2==F3) on the RAW ingest surface (equipment_values) as a
//     count-TOLERANT whole-surface fingerprint — per-key is inherently noisy
//     there (independent emit legs, measured 0.04% row variance), so the raw
//     layer keeps the tolerant whole-surface check rather than per-key exact.
//  3. Int-overflow bound: on EACH side independently, no row's running_time may
//     exceed its bucket's wall-clock span × overflowFactor. This is the L8 P0
//     sentinel (running_time overflowed to ~112,000,000 vs ~11,195 correct);
//     an int4-class blow-up is astronomically past any physical shift span.
//
// NATURAL KEY, NOT id_equipment: surrogate ids are not guaranteed stable across
// F2 (shadow_go_port in the main DB) and F3 (public in packiot_shadow) — refsync
// happens to preserve them today, but a re-provision would renumber F3 and an
// id-join would then silently mis-match. (nm_equipment, tp_equipment) is the
// stable key — and it must be the COMPOSITE, because a machine (tp=1) and a
// line (tp=3) legitimately share a name (e.g. BREYER1 is both).
//
// SCHEMA ROUTING: each query has ONE %s for the DATA table's schema
// (shadow_go_port for F2, public for F3). The equipments dimension is ALWAYS
// public.<equipments> — in the F2 pool "public" resolves to the main DB's
// equipments, in the F3 pool it resolves to packiot_shadow's, each correct for
// its own id space.
//
// SETTLED WINDOW: identical to the live loop — ts_end < now()-2h (bucket fully
// closed) over a 3-day lookback. A just-restarted stack has NOT converged the
// current minute, so comparing the open bucket would false-fail; the 3-day
// history is unaffected by the deploy.
//
// ANCHOR ON now(), NEVER max(ts_value) (task #42): F3's equipment_runtime_shift
// / _1hour carry FUTURE-DATED rows (~2026-08-14, uniform across all lines — a
// rollup forward-fill horizon artifact, benign). Measured 2026-07-16: 5518 such
// rows exist in the 3-day lookback, and ALL are excluded by the ts_end<now()-2h
// upper bound (future ts_value ⇒ future ts_end ⇒ fails the closed-past-bucket
// clause). Do NOT "optimize" this window to key off max(ts_value) — that would
// anchor on 2026-08-14 and silently drag the whole comparison into empty/future
// buckets. The upper bound MUST stay a wall-clock-now closed-past predicate.
//
// SKIP-ON-EMPTY (cold-stack guard): both sides empty for a surface → SKIP (no
// data to compare). Exactly one side entirely empty → SKIP with a loud warn
// (F3 rollup not yet converged / infra, NOT a determinism regression — the live
// bake gauge catches a SUSTAINED one-sided outage). Only when BOTH sides have
// data does a per-key mismatch or a one-sided key FAIL the gate.
package bake

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// overflowFactor is the slop above a bucket's wall-clock span that a legit
// running_time may occupy. Measured on live staging 2026-07-15: the tightest
// legit running_time/span ratio is exactly 1.0000 (running_time can never
// physically exceed the bucket it is measured in), so 1.05 gives 5% headroom
// for rounding/boundary overlap while still catching the L8 overflow (112M vs a
// ~30,600s shift span = ratio ~3600, ~3400× past the bound).
const overflowFactor = 1.05

// sentinelSurfaces are the F2-vs-F3 identity surfaces the gate compares.
// Each SQL takes ONE %s (the data schema) and one $1 (id_enterprise) and
// returns rows of (natkey text, fingerprint text). The fingerprint is the same
// pipe-delimited "count|sum|sum" IdentityMatch consumes.
var sentinelSurfaces = []struct {
	Name          string
	SQL           string
	CountTolerant bool
}{
	// DERIVED grain — per-line, count-EXACT (a runtime_shift row-count gap is
	// structural: provisioning diverged). 3-field: count | gross | running_time.
	{Name: "equipment_runtime_shift", CountTolerant: false, SQL: `
		SELECT e.nm_equipment || '|' || e.tp_equipment AS natkey,
		       count(*)::text
		         || '|' || COALESCE(sum(s.gross)::numeric(20,3),0)::text
		         || '|' || COALESCE(sum(s.running_time)::numeric(20,1),0)::text AS fp
		  FROM %s.equipment_runtime_shift s
		  JOIN public.equipments e ON e.id_equipment = s.id_equipment
		 WHERE e.id_enterprise = $1
		   AND s.ts_value >= now() - interval '3 days'
		   AND s.ts_end   <  now() - interval '2 hours'
		 GROUP BY 1`},
	// DERIVED grain — per-line, count-EXACT. 2-field: count | gross_production.
	{Name: "production_orders_runtime", CountTolerant: false, SQL: `
		SELECT e.nm_equipment || '|' || e.tp_equipment AS natkey,
		       count(*)::text
		         || '|' || COALESCE(sum(r.gross_production)::numeric(20,3),0)::text AS fp
		  FROM %s.production_orders_runtime r
		  JOIN public.equipments e ON e.id_equipment = r.id_equipment
		 WHERE e.id_enterprise = $1
		   AND lower(r.runtime_timerange) >= now() - interval '3 days'
		   AND upper(r.runtime_timerange) <  now() - interval '2 hours'
		 GROUP BY 1`},
	// RAW ingest — whole-surface, count-TOLERANT (independent emit legs). A
	// single synthetic key so it flows through the same per-key machinery.
	// 3-field: count | net | gross. Window matches identitySurfaces[0].
	{Name: "equipment_values_raw_24h", CountTolerant: true, SQL: `
		SELECT '__all__' AS natkey,
		       count(*)::text
		         || '|' || COALESCE(sum(net_production_incr)::numeric(20,3),0)::text
		         || '|' || COALESCE(sum(gross_production_incr)::numeric(20,3),0)::text AS fp
		  FROM %s.equipment_values
		 WHERE id_enterprise = $1
		   AND ts_value >= date_trunc('hour', now() - interval '25 hours')
		   AND ts_value <  date_trunc('hour', now() - interval '1 hour')`},
}

// overflowSurfaces run on EACH side independently. Each SQL takes ONE %s (data
// schema) + $1 (id_enterprise) and returns ONLY violating rows: natkey,
// running_time, span_seconds. A non-empty result = an overflow regression.
var overflowSurfaces = []struct {
	Name string
	SQL  string
}{
	{Name: "equipment_runtime_shift", SQL: `
		SELECT e.nm_equipment || '|' || e.tp_equipment AS natkey,
		       s.running_time::text,
		       EXTRACT(epoch FROM (s.ts_end - s.ts_value))::text AS span
		  FROM %s.equipment_runtime_shift s
		  JOIN public.equipments e ON e.id_equipment = s.id_equipment
		 WHERE e.id_enterprise = $1
		   AND s.ts_value >= now() - interval '3 days'
		   AND s.ts_end   <  now() - interval '2 hours'
		   AND ( s.running_time < 0
		         OR s.running_time > GREATEST(EXTRACT(epoch FROM (s.ts_end - s.ts_value)), 60) * ` + overflowFactorSQL + ` )
		 ORDER BY s.running_time DESC
		 LIMIT 20`},
	{Name: "production_orders_runtime", SQL: `
		SELECT e.nm_equipment || '|' || e.tp_equipment AS natkey,
		       r.running_time::text,
		       EXTRACT(epoch FROM (upper(r.runtime_timerange) - lower(r.runtime_timerange)))::text AS span
		  FROM %s.production_orders_runtime r
		  JOIN public.equipments e ON e.id_equipment = r.id_equipment
		 WHERE e.id_enterprise = $1
		   AND lower(r.runtime_timerange) >= now() - interval '3 days'
		   AND upper(r.runtime_timerange) <  now() - interval '2 hours'
		   AND ( r.running_time < 0
		         OR r.running_time > GREATEST(EXTRACT(epoch FROM (upper(r.runtime_timerange) - lower(r.runtime_timerange))), 60) * ` + overflowFactorSQL + ` )
		 ORDER BY r.running_time DESC
		 LIMIT 20`},
}

// overflowFactorSQL keeps the SQL literal in lockstep with the Go const so the
// two never drift (the bound is asserted in both places from one source).
const overflowFactorSQL = "1.05"

// SurfaceOutcome is one (surface × enterprise) determinism result.
type SurfaceOutcome struct {
	Surface    string
	Enterprise int
	Status     string // "PASS" | "FAIL" | "SKIP"
	Compared   int    // keys that matched (PASS) — informational
	Details    []string
}

// OverflowOutcome is one (surface × side × enterprise) overflow result.
type OverflowOutcome struct {
	Surface    string
	Side       string // "F2" | "F3"
	Enterprise int
	Violations []string // empty = clean
}

// SentinelReport aggregates every outcome and knows whether the gate failed.
type SentinelReport struct {
	Surfaces []SurfaceOutcome
	Overflow []OverflowOutcome
}

// Failed is true if ANY determinism surface FAILed or ANY overflow violation
// exists. SKIPs never fail the gate (cold-stack / no-data guard).
func (r *SentinelReport) Failed() bool {
	for _, s := range r.Surfaces {
		if s.Status == "FAIL" {
			return true
		}
	}
	for _, o := range r.Overflow {
		if len(o.Violations) > 0 {
			return true
		}
	}
	return false
}

// String renders a compact, log-friendly PASS/FAIL report.
func (r *SentinelReport) String() string {
	var b strings.Builder
	pass, fail, skip := 0, 0, 0
	for _, s := range r.Surfaces {
		switch s.Status {
		case "PASS":
			pass++
		case "FAIL":
			fail++
		case "SKIP":
			skip++
		}
		fmt.Fprintf(&b, "  [%s] identity %s ent=%d compared=%d\n", s.Status, s.Surface, s.Enterprise, s.Compared)
		for _, d := range s.Details {
			fmt.Fprintf(&b, "        - %s\n", d)
		}
	}
	ovf := 0
	for _, o := range r.Overflow {
		status := "PASS"
		if len(o.Violations) > 0 {
			status = "FAIL"
			ovf += len(o.Violations)
		}
		fmt.Fprintf(&b, "  [%s] overflow %s/%s ent=%d violations=%d\n", status, o.Surface, o.Side, o.Enterprise, len(o.Violations))
		for _, v := range o.Violations {
			fmt.Fprintf(&b, "        - %s\n", v)
		}
	}
	verdict := "PASS"
	if r.Failed() {
		verdict = "FAIL"
	}
	fmt.Fprintf(&b, "  VERDICT: %s (identity pass=%d fail=%d skip=%d, overflow violations=%d)", verdict, pass, fail, skip, ovf)
	return b.String()
}

// compareKeyMaps is the PURE determinism comparison for one surface×enterprise.
// Extracted from all I/O so the gate's decision logic is unit-testable without a
// DB (the queries are thin delivery; THIS is the load-bearing verdict).
func compareKeyMaps(surface string, ent int, f2, f3 map[string]string, countTol bool) SurfaceOutcome {
	// Cold-stack / no-data guard.
	if len(f2) == 0 && len(f3) == 0 {
		return SurfaceOutcome{surface, ent, "SKIP", 0,
			[]string{"no rows in settled window on either side — nothing to compare"}}
	}
	if len(f2) == 0 || len(f3) == 0 {
		side, other := "F2", len(f3)
		if len(f3) == 0 {
			side, other = "F3", len(f2)
		}
		return SurfaceOutcome{surface, ent, "SKIP", 0,
			[]string{fmt.Sprintf("%s side entirely empty while other has %d keys — stack not converged; not gating (live bake gauge tracks sustained one-sidedness)", side, other)}}
	}

	var details []string
	compared := 0
	for _, k := range sortedUnion(f2, f3) {
		fa, okA := f2[k]
		fb, okB := f3[k]
		switch {
		case okA && !okB:
			details = append(details, fmt.Sprintf("key %q present in F2 (%s) but ABSENT in F3", k, fa))
		case !okA && okB:
			details = append(details, fmt.Sprintf("key %q present in F3 (%s) but ABSENT in F2", k, fb))
		default:
			if match, detail := IdentityMatch(fa, fb, countTol); match {
				compared++
			} else {
				details = append(details, fmt.Sprintf("key %q DIVERGED: %s  [F2=%s F3=%s]", k, detail, fa, fb))
			}
		}
	}
	status := "PASS"
	if len(details) > 0 {
		status = "FAIL"
	}
	return SurfaceOutcome{surface, ent, status, compared, details}
}

func sortedUnion(a, b map[string]string) []string {
	seen := make(map[string]struct{}, len(a)+len(b))
	for k := range a {
		seen[k] = struct{}{}
	}
	for k := range b {
		seen[k] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// fetchKeyMap runs one identity surface (schema-substituted, enterprise-bound)
// and returns natkey → fingerprint.
func fetchKeyMap(ctx context.Context, pool *pgxpool.Pool, sql, schema string, ent int) (map[string]string, error) {
	rows, err := pool.Query(ctx, fmt.Sprintf(sql, schema), ent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := make(map[string]string)
	for rows.Next() {
		var k, fp string
		if err := rows.Scan(&k, &fp); err != nil {
			return nil, err
		}
		m[k] = fp
	}
	return m, rows.Err()
}

// fetchOverflow runs one overflow surface (schema-substituted, enterprise-bound)
// and returns a violation-detail string per offending row (already filtered to
// violations only by the WHERE clause).
func fetchOverflow(ctx context.Context, pool *pgxpool.Pool, sql, schema string, ent int) ([]string, error) {
	rows, err := pool.Query(ctx, fmt.Sprintf(sql, schema), ent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var natkey, rt, span string
		if err := rows.Scan(&natkey, &rt, &span); err != nil {
			return nil, err
		}
		out = append(out, fmt.Sprintf("key %q running_time=%s exceeds span=%ss × %.2f (int-overflow class)", natkey, rt, span, overflowFactor))
	}
	return out, rows.Err()
}

// RunSentinel executes the full gate against F2 (f2 pool → shadow_go_port) and
// F3 (f3 pool → public in packiot_shadow) across the given enterprises, and
// returns a report. It NEVER returns an error for a data mismatch — a mismatch
// is a report FAIL, not a Go error; a returned error means the check itself
// could not run (query failed), which the caller must also treat as gate-fail
// (fail-closed: a sentinel that cannot run must not silently pass a deploy).
func RunSentinel(ctx context.Context, f2, f3 *pgxpool.Pool, enterprises []int) (*SentinelReport, error) {
	rep := &SentinelReport{}
	for _, ent := range enterprises {
		for _, s := range sentinelSurfaces {
			f2m, err := fetchKeyMap(ctx, f2, s.SQL, "shadow_go_port", ent)
			if err != nil {
				return rep, fmt.Errorf("F2 %s ent=%d: %w", s.Name, ent, err)
			}
			f3m, err := fetchKeyMap(ctx, f3, s.SQL, "public", ent)
			if err != nil {
				return rep, fmt.Errorf("F3 %s ent=%d: %w", s.Name, ent, err)
			}
			rep.Surfaces = append(rep.Surfaces, compareKeyMaps(s.Name, ent, f2m, f3m, s.CountTolerant))
		}
		for _, o := range overflowSurfaces {
			for _, sd := range []struct {
				side, schema string
				pool         *pgxpool.Pool
			}{{"F2", "shadow_go_port", f2}, {"F3", "public", f3}} {
				v, err := fetchOverflow(ctx, sd.pool, o.SQL, sd.schema, ent)
				if err != nil {
					return rep, fmt.Errorf("overflow %s/%s ent=%d: %w", o.Name, sd.side, ent, err)
				}
				rep.Overflow = append(rep.Overflow, OverflowOutcome{o.Name, sd.side, ent, v})
			}
		}
	}
	return rep, nil
}
