// sentinel.go — the F3 int-overflow SENTINEL that runs as a deploy-time CI gate
// (cmd/oeecloud-worker --identity-sentinel), turning a determinism/overflow check
// into a self-enforcing pipeline gate instead of a manual comparator run.
//
// ── HISTORY: WHY THIS IS OVERFLOW-ONLY NOW (ADR-0032 Step 5) ──────────────────
// This started life as an F2/F3 IDENTITY sentinel with three gates:
//   GATE 1 (byte-exact core F2==F3) + GATE 3 (raw row-count F2==F3) — both were
//     two-plane EQUALITY checks that proved the #276 Calc cutover was deterministic
//     during the 3-flow bake; and
//   GATE 2 (int-overflow, per-plane) — no row's running_time may exceed its bucket
//     wall-clock span × overflowFactor. This is the guard that caught the L8 P0
//     regression (running_time overflowed to ~112,000,000 vs ~11,195 correct).
//
// The F3 single-flow collapse DROPPED the F2 (shadow_go_port) plane, so GATE 1/3
// (which compare F2 to F3) no longer have a second plane and were retired. GATE 2
// was never a comparison — it is a per-plane invariant — so it SURVIVES, now run
// on F3 (`public` in packiot_shadow) only. That is this file.
//
// The overflow class also has a DB-layer backstop now: the `*_oee_bounds` CHECK
// constraints (BETWEEN 0 AND 1, #663) reject an overflow-driven oee blow-up at the
// write. This sentinel catches the running_time overflow itself, upstream of that.
//
// SETTLED WINDOW: ts_end < now()-3h (bucket fully closed) AND ts_value within the
// last 3 days (bounded scan). ANCHOR ON now(), NEVER max(ts_value) (task #42).
//
// ENFORCE MODE (caller-side, IDENTITY_SENTINEL_ENFORCE): a non-zero exit is a
// ::warning:: in soft-launch and FAILS the deploy when enforcing. The binary
// ALWAYS exits non-zero on any violation (or if the check could not run —
// fail-closed: a sentinel that cannot evaluate must not silently pass a deploy).

package bake

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// overflowFactor is the slop above a bucket's wall-clock span that a legit
// running_time may occupy — 5% absorbs cagg rounding/boundary overlap while still
// catching the L8 overflow class (112M vs an ~11k-second bucket).
const overflowFactor = 1.05

// overflowFactorSQL keeps the SQL literal in lockstep with the Go const.
const overflowFactorSQL = "1.05"

// overflowSurfaces — GATE 2. Run per-plane; return ONLY violating rows
// (natkey, running_time, span_seconds). Non-empty = overflow.
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

// OverflowOutcome is one (surface × enterprise) overflow result on F3.
type OverflowOutcome struct {
	Surface    string
	Enterprise int
	Violations []string
}

// SentinelReport aggregates every overflow outcome and knows whether the gate
// failed. (The former F2/F3 identity Surfaces are gone with the F2 plane.)
type SentinelReport struct {
	Overflow []OverflowOutcome
}

// Failed is true if ANY overflow violation exists.
func (r *SentinelReport) Failed() bool {
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
	ovf := 0
	for _, o := range r.Overflow {
		status := "PASS"
		if len(o.Violations) > 0 {
			status = "FAIL"
			ovf += len(o.Violations)
		}
		fmt.Fprintf(&b, "  [%s] overflow %s ent=%d violations=%d\n", status, o.Surface, o.Enterprise, len(o.Violations))
		for _, v := range o.Violations {
			fmt.Fprintf(&b, "        - %s\n", v)
		}
	}
	verdict := "PASS"
	if r.Failed() {
		verdict = "FAIL"
	}
	fmt.Fprintf(&b, "  VERDICT: %s (F3 overflow violations=%d)", verdict, ovf)
	return b.String()
}

// fetchOverflow runs one overflow surface and returns the violating rows.
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

// RunSentinel executes the F3 int-overflow gate against the F3 pool (→ public in
// packiot_shadow) across the given enterprises. It NEVER returns an error for a
// data violation — a violation is a report FAIL. A returned error means the check
// itself could not run (query failed), which the caller must treat as gate-fail
// (fail-closed: a sentinel that cannot run must not silently pass a deploy).
func RunSentinel(ctx context.Context, f3 *pgxpool.Pool, enterprises []int) (*SentinelReport, error) {
	rep := &SentinelReport{}
	for _, ent := range enterprises {
		for _, o := range overflowSurfaces {
			v, err := fetchOverflow(ctx, f3, o.SQL, "public", ent)
			if err != nil {
				return rep, fmt.Errorf("overflow %s ent=%d: %w", o.Name, ent, err)
			}
			rep.Overflow = append(rep.Overflow, OverflowOutcome{Surface: o.Name, Enterprise: ent, Violations: v})
		}
	}
	return rep, nil
}
