// sentinel.go — the F2/F3 identity + int-overflow SENTINEL that runs as a
// deploy-time CI gate (cmd/oeecloud-worker --identity-sentinel), turning the
// continuous in-process bake (RunIdentityTick, which only moves a Prometheus
// gauge) into a hard pass/fail a deploy run can go red on.
//
// ── WHAT "IDENTITY" MEANS AFTER THE #276 CALC CUTOVER (tasks #43 + live #474) ──
// F2 (shadow_go_port) is the deliberately-RAW control; F3 (public in
// packiot_shadow) runs CALC_CUTOVER_REFACTORED (absolute-totalizer→delta) plus
// the #456 line-suppression. So F2 and F3 DO NOT agree on the COUNTER surface by
// design, and — verified on live staging 2026-07-16 — the divergence has ≥3
// classes that no single runtime signature cleanly separates:
//   - F2 huge (raw absolute totalizer summed): L8 ~4.9e9, FLEXO, L4 (F2 oee>1);
//   - F2 UNDER-counts vs F3: L3 (F2 gross 0 vs F3 184855), L5 (131k vs 346k),
//     with F2 oee ≤ 1.0 — so "gate gross where F2 oee ≤ 1.0" ALSO false-fails;
//   - byte-exact: L6, L10.
//
// Likewise "F3 line oee ≤ 1.0" is FALSE on live (F3 L4 2.68, L8 5349 — the known
// tp=3-line confound, session 85: lines read their own tp=3 stream, prod itself
// has oee>1.0), so it cannot gate either.
//
// The determinism that DOES hold across the cutover, byte-exact on EVERY line
// (incl. absolute-control lines) and STABLE (does not transiently lag), is the
// EVENT-DERIVED CORE: count, running_time, duration. The rollup-COMPUTED time
// columns (available_time / stopped_time / downtime / oee) transiently lag on F3
// for the newest just-settled bucket (observed: HOTMADAG showed F3 avail/
// stopped/downtime = 0 while running_time=0 and duration=228600 were already
// correct, then converged minutes later) — so they are NOT gated.
//
// THE GATES (all SELECT-only, both planes):
//
//	GATE 1 (PRIMARY determinism) — F2==F3 BYTE-EXACT on the event-derived core
//	  {count, running_time, duration} per natural key, EVERY equipment. This is
//	  running_time-byte-exact as the primary assertion (task #43's "strongest,
//	  cleanest determinism gate"). A gap of ANY size fails.
//	GATE 2 (int-overflow) — on EACH plane, no row's running_time may exceed its
//	  bucket wall-clock span × overflowFactor. The L8 P0 sentinel (running_time
//	  overflowed to ~112,000,000 vs ~11,195 correct).
//	GATE 3 (raw ingest determinism) — F2==F3 on the equipment_values ROW COUNT
//	  only, count-tolerant (independent emit legs ~0.04% noisy). The gross/net
//	  SUMS are NOT compared: F2 sums absolute totalizers (~9.2e9) vs F3 deltas
//	  (~3.4e6) by design.
//
// COUNTERS ARE REPORTED, NOT GATED: gross/net F2-vs-F3 divergences are printed
// as INFO (with each line's F2 oee) so the deploy log keeps the adversarial
// signal visible for a human, but they NEVER affect the verdict — they are a
// CORRECTNESS question (F3-vs-prod) for the separate S2 readiness gate, which
// this SELECT-only staging worker cannot run (no prod access). If counters are
// ever brought into determinism, promote the INFO to a gated surface here.
//
// NATURAL KEY, NOT id_equipment: surrogate ids are not guaranteed stable across
// F2 and F3. (nm_equipment, tp_equipment) is the stable key — and MUST be the
// COMPOSITE, because a machine (tp=1) and a line (tp=3) legitimately share a
// name (e.g. BREYER1 is both). Verified covering all six CPACK tp=3 lines
// (L3/L4/L5/L6/L8/L10) via GROUP BY, never a hardcoded id list.
//
// SCHEMA ROUTING: each query has ONE %s for the DATA table's schema
// (shadow_go_port for F2, public for F3). The equipments dimension is ALWAYS
// public.<equipments> — in the F2 pool "public" is the main DB's equipments, in
// the F3 pool it is packiot_shadow's, each correct for its own id space.
//
// SETTLED WINDOW: ts_end < now()-settleMargin (bucket fully closed AND F3's
// rollup converged) over a 3-day lookback. The margin is 3h (not 2h): the
// rollup-computed columns were seen to lag ~2h behind close, so 3h buys headroom
// for the event-derived core to be fully settled on F3. A just-restarted stack
// has NOT converged the current minute; the 3-day history is unaffected by the
// deploy.
//
// ANCHOR ON now(), NEVER max(ts_value) (task #42): F3's equipment_runtime_shift/
// _1hour carry FUTURE-DATED rows (~2026-08-14, a rollup forward-fill horizon
// artifact, benign; 5518 in the 3-day lookback on 2026-07-16). ALL are excluded
// by the ts_end<now()-margin upper bound (future ts_value ⇒ future ts_end ⇒
// fails the closed-past clause). Do NOT "optimize" this window to key off
// max(ts_value) — it would anchor on 2026-08-14 and drag the comparison into
// empty/future buckets.
//
// SKIP-ON-EMPTY (cold-stack guard): both sides empty for a surface → SKIP.
// Exactly one side entirely empty → SKIP with a loud warn (F3 not converged /
// infra, NOT a determinism regression). Only when BOTH sides have data does a
// per-key mismatch or one-sided key FAIL the gate.
package bake

import (
	"context"
	"fmt"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// overflowFactor is the slop above a bucket's wall-clock span that a legit
// running_time may occupy. Measured on live staging: the tightest legit
// running_time/span ratio is exactly 1.0000 (running_time can never physically
// exceed the bucket it is measured in), so 1.05 gives 5% headroom for
// rounding/boundary overlap while still catching the L8 overflow (112M vs a
// ~30,600s shift span = ~3400× past the bound).
const overflowFactor = 1.05

// overflowFactorSQL keeps the SQL literal in lockstep with the Go const.
const overflowFactorSQL = "1.05"

// counterInfoTol is the relative band beyond which a gross/net F2-vs-F3
// difference is printed as INFO (non-gating). Same 1% as identityTol — purely
// to keep the log quiet on rounding-level noise; it never affects the verdict.
const counterInfoTol = 0.01

// planeRow is the per-natural-key aggregate for one plane over the settled
// window. The core {Count, RunningTime, Duration} is the gated byte-exact
// surface; Gross/Net/MaxOEE are carried for the NON-GATED counter INFO.
type planeRow struct {
	Count, RunningTime, Duration int64
	Gross, Net, MaxOEE           float64
}

// coreFingerprint is the byte-exact, non-lagging determinism surface (the
// event-derived core shared across the cutover). Compared with STRICT string
// equality — a running_time (or count/duration) gap of ANY size is a bug.
func (r planeRow) coreFingerprint() string {
	return fmt.Sprintf("%d|%d|%d", r.Count, r.RunningTime, r.Duration)
}

// lineSurfaces are the F2-vs-F3 identity surfaces the gate compares per natural
// key. Each SQL takes ONE %s (data schema) + $1 (id_enterprise) and returns:
//
//	natkey, count, running_time, duration, gross, net, max_oee
//
// (production_orders_runtime has no `duration` column → selects 0, a no-op that
// stays byte-exact across planes.)
var lineSurfaces = []struct{ Name, SQL string }{
	{Name: "equipment_runtime_shift", SQL: `
		SELECT e.nm_equipment || '|' || e.tp_equipment AS natkey,
		       count(*),
		       COALESCE(sum(s.running_time),0),
		       COALESCE(sum(s.duration),0),
		       COALESCE(sum(s.gross)::double precision,0),
		       COALESCE(sum(s.net)::double precision,0),
		       COALESCE(max(s.oee)::double precision,0)
		  FROM %s.equipment_runtime_shift s
		  JOIN public.equipments e ON e.id_equipment = s.id_equipment
		 WHERE e.id_enterprise = $1
		   AND s.ts_value >= now() - interval '3 days'
		   AND s.ts_end   <  now() - interval '3 hours'
		 GROUP BY 1`},
	{Name: "production_orders_runtime", SQL: `
		SELECT e.nm_equipment || '|' || e.tp_equipment AS natkey,
		       count(*),
		       COALESCE(sum(r.running_time),0),
		       0::bigint,
		       COALESCE(sum(r.gross_production)::double precision,0),
		       COALESCE(sum(r.net_production)::double precision,0),
		       COALESCE(max(r.oee)::double precision,0)
		  FROM %s.production_orders_runtime r
		  JOIN public.equipments e ON e.id_equipment = r.id_equipment
		 WHERE e.id_enterprise = $1
		   AND lower(r.runtime_timerange) >= now() - interval '3 days'
		   AND upper(r.runtime_timerange) <  now() - interval '3 hours'
		 GROUP BY 1`},
}

// rawCountSurface — GATE 3. F2==F3 on the equipment_values ROW COUNT only,
// count-tolerant. Returns a single "__all__" natkey → count.
const rawCountSurface = `
	SELECT '__all__' AS natkey, count(*)::bigint AS n
	  FROM %s.equipment_values
	 WHERE id_enterprise = $1
	   AND ts_value >= date_trunc('hour', now() - interval '25 hours')
	   AND ts_value <  date_trunc('hour', now() - interval '1 hour')`

// overflowSurfaces — GATE 2. Run on EACH plane independently; return ONLY
// violating rows (natkey, running_time, span_seconds). Non-empty = overflow.
var overflowSurfaces = []struct{ Name, SQL string }{
	{Name: "equipment_runtime_shift", SQL: `
		SELECT e.nm_equipment || '|' || e.tp_equipment AS natkey,
		       s.running_time::text,
		       EXTRACT(epoch FROM (s.ts_end - s.ts_value))::text AS span
		  FROM %s.equipment_runtime_shift s
		  JOIN public.equipments e ON e.id_equipment = s.id_equipment
		 WHERE e.id_enterprise = $1
		   AND s.ts_value >= now() - interval '3 days'
		   AND s.ts_end   <  now() - interval '3 hours'
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
		   AND upper(r.runtime_timerange) <  now() - interval '3 hours'
		   AND ( r.running_time < 0
		         OR r.running_time > GREATEST(EXTRACT(epoch FROM (upper(r.runtime_timerange) - lower(r.runtime_timerange))), 60) * ` + overflowFactorSQL + ` )
		 ORDER BY r.running_time DESC
		 LIMIT 20`},
}

// SurfaceOutcome is one (surface × enterprise) determinism result.
type SurfaceOutcome struct {
	Surface    string
	Enterprise int
	Status     string   // "PASS" | "FAIL" | "SKIP"
	Compared   int      // keys whose core fingerprint matched — informational
	Details    []string // GATED failures (core divergence / key presence)
	Info       []string // NON-GATED counter divergences (visibility only)
}

// OverflowOutcome is one (surface × side × enterprise) overflow result.
type OverflowOutcome struct {
	Surface    string
	Side       string // "F2" | "F3"
	Enterprise int
	Violations []string
}

// SentinelReport aggregates every outcome and knows whether the gate failed.
type SentinelReport struct {
	Surfaces []SurfaceOutcome
	Overflow []OverflowOutcome
}

// Failed is true if ANY determinism surface FAILed or ANY overflow violation
// exists. SKIPs and Info (counter divergences) never fail the gate.
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
		fmt.Fprintf(&b, "  [%s] identity %s ent=%d compared=%d info=%d\n", s.Status, s.Surface, s.Enterprise, s.Compared, len(s.Info))
		for _, d := range s.Details {
			fmt.Fprintf(&b, "        - %s\n", d)
		}
		for _, i := range s.Info {
			fmt.Fprintf(&b, "        · counter-info (NOT gated) %s\n", i)
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

// compareLines is the PURE determinism verdict for one line surface×enterprise.
// GATE 1 (core {count,running_time,duration} byte-exact) is the only gated
// check; counter divergences are recorded as non-gating Info.
func compareLines(surface string, ent int, f2, f3 map[string]planeRow) SurfaceOutcome {
	if len(f2) == 0 && len(f3) == 0 {
		return SurfaceOutcome{surface, ent, "SKIP", 0,
			[]string{"no rows in settled window on either side — nothing to compare"}, nil}
	}
	if len(f2) == 0 || len(f3) == 0 {
		side, other := "F2", len(f3)
		if len(f3) == 0 {
			side, other = "F3", len(f2)
		}
		return SurfaceOutcome{surface, ent, "SKIP", 0,
			[]string{fmt.Sprintf("%s side entirely empty while other has %d keys — stack not converged; not gating", side, other)}, nil}
	}

	var details, info []string
	compared := 0
	for _, k := range sortedRowUnion(f2, f3) {
		a, okA := f2[k]
		b, okB := f3[k]
		switch {
		case okA && !okB:
			details = append(details, fmt.Sprintf("key %q present in F2 but ABSENT in F3", k))
			continue
		case !okA && okB:
			details = append(details, fmt.Sprintf("key %q present in F3 but ABSENT in F2", k))
			continue
		}
		// GATE 1 — event-derived core byte-exact (strict).
		if a.coreFingerprint() != b.coreFingerprint() {
			details = append(details, fmt.Sprintf("key %q CORE diverged (byte-exact required): F2=[%s] F3=[%s] (count|running_time|duration)",
				k, a.coreFingerprint(), b.coreFingerprint()))
			continue
		}
		compared++
		// NON-GATED counter visibility.
		if counterDiverges(a, b) {
			info = append(info, fmt.Sprintf("%s gross F2=%.1f/F3=%.1f net F2=%.1f/F3=%.1f (F2 oee=%.2f) — cutover-affected counter, correctness = S2 gate",
				k, a.Gross, b.Gross, a.Net, b.Net, a.MaxOEE))
		}
	}
	status := "PASS"
	if len(details) > 0 {
		status = "FAIL"
	}
	return SurfaceOutcome{surface, ent, status, compared, details, info}
}

// counterDiverges reports whether F2/F3 gross or net differ beyond
// counterInfoTol (relative). Pure; used only to decide whether to emit INFO.
func counterDiverges(a, b planeRow) bool {
	return relDiff(a.Gross, b.Gross) > counterInfoTol || relDiff(a.Net, b.Net) > counterInfoTol
}

func relDiff(x, y float64) float64 {
	d := x - y
	if d < 0 {
		d = -d
	}
	m := x
	if y > m {
		m = y
	}
	if -x > m {
		m = -x
	}
	if -y > m {
		m = -y
	}
	if m < 1 {
		m = 1
	}
	return d / m
}

// compareRawCount is GATE 3: F2==F3 on the raw equipment_values row count only,
// count-tolerant. PURE for testability.
func compareRawCount(ent int, f2, f3 int64, f2Empty, f3Empty bool) SurfaceOutcome {
	const surface = "equipment_values_raw_24h"
	if f2Empty && f3Empty {
		return SurfaceOutcome{surface, ent, "SKIP", 0,
			[]string{"no raw rows in settled window on either side"}, nil}
	}
	if f2Empty || f3Empty {
		side := "F2"
		if f3Empty {
			side = "F3"
		}
		return SurfaceOutcome{surface, ent, "SKIP", 0,
			[]string{fmt.Sprintf("%s raw side entirely empty — stack not converged; not gating", side)}, nil}
	}
	if match, detail := IdentityMatch(fmt.Sprintf("%d", f2), fmt.Sprintf("%d", f3), true); !match {
		return SurfaceOutcome{surface, ent, "FAIL", 0,
			[]string{fmt.Sprintf("raw row count diverged beyond tolerance: %s [F2=%d F3=%d]", detail, f2, f3)}, nil}
	}
	return SurfaceOutcome{surface, ent, "PASS", 1, nil, nil}
}

func sortedRowUnion(a, b map[string]planeRow) []string {
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

// fetchLineRows runs one line surface (schema-substituted, enterprise-bound) and
// returns natkey → planeRow.
func fetchLineRows(ctx context.Context, pool *pgxpool.Pool, sql, schema string, ent int) (map[string]planeRow, error) {
	rows, err := pool.Query(ctx, fmt.Sprintf(sql, schema), ent)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	m := make(map[string]planeRow)
	for rows.Next() {
		var k string
		var r planeRow
		if err := rows.Scan(&k, &r.Count, &r.RunningTime, &r.Duration, &r.Gross, &r.Net, &r.MaxOEE); err != nil {
			return nil, err
		}
		m[k] = r
	}
	return m, rows.Err()
}

// fetchRawCount runs GATE 3's count query and returns (count, empty, error).
func fetchRawCount(ctx context.Context, pool *pgxpool.Pool, schema string, ent int) (int64, bool, error) {
	var natkey string
	var n int64
	err := pool.QueryRow(ctx, fmt.Sprintf(rawCountSurface, schema), ent).Scan(&natkey, &n)
	if err != nil {
		return 0, false, err
	}
	return n, n == 0, nil
}

// fetchOverflow runs one overflow surface and returns a violation-detail string
// per offending row (already filtered to violations only by the WHERE clause).
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
// F3 (f3 pool → public in packiot_shadow) across the given enterprises. It NEVER
// returns an error for a data mismatch — a mismatch is a report FAIL. A returned
// error means the check itself could not run (query failed), which the caller
// must treat as gate-fail (fail-closed: a sentinel that cannot run must not
// silently pass a deploy).
func RunSentinel(ctx context.Context, f2, f3 *pgxpool.Pool, enterprises []int) (*SentinelReport, error) {
	rep := &SentinelReport{}
	for _, ent := range enterprises {
		// GATE 1 — line surfaces (core byte-exact + counter INFO).
		for _, s := range lineSurfaces {
			f2r, err := fetchLineRows(ctx, f2, s.SQL, "shadow_go_port", ent)
			if err != nil {
				return rep, fmt.Errorf("F2 %s ent=%d: %w", s.Name, ent, err)
			}
			f3r, err := fetchLineRows(ctx, f3, s.SQL, "public", ent)
			if err != nil {
				return rep, fmt.Errorf("F3 %s ent=%d: %w", s.Name, ent, err)
			}
			rep.Surfaces = append(rep.Surfaces, compareLines(s.Name, ent, f2r, f3r))
		}
		// GATE 3 — raw ingest row count.
		f2n, f2empty, err := fetchRawCount(ctx, f2, "shadow_go_port", ent)
		if err != nil {
			return rep, fmt.Errorf("F2 raw count ent=%d: %w", ent, err)
		}
		f3n, f3empty, err := fetchRawCount(ctx, f3, "public", ent)
		if err != nil {
			return rep, fmt.Errorf("F3 raw count ent=%d: %w", ent, err)
		}
		rep.Surfaces = append(rep.Surfaces, compareRawCount(ent, f2n, f3n, f2empty, f3empty))
		// GATE 2 — overflow, each plane independently.
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
