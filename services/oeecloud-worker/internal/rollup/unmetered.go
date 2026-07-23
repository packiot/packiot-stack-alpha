// unmetered.go — runtime-rollup-unmetered (ledger name): the
// "not-metered machine" correction pass (OEE audit Defect B, low-risk
// NULL-not-0 variant).
//
// THE DEFECT:
//   A tp_equipment=1 (machine) grain row belongs to one of two worlds:
//     (a) MACHINE-METERED enterprises — every machine emits its own
//         count/target topics, so a per-machine OEE is real. Prod (and
//         our shift grain, via the machine-level UNION selector) DOES
//         compute these. The machine-level set is ROLLUP_MACHINE_LEVEL_
//         ENTERPRISES (prod hardcodes {6} → config).
//     (b) LINE-METERED enterprises (e.g. CPACK) — production is metered
//         only at the LINE (tp=3). The individual machines carry no
//         per-machine count/target signal at all. On staging CPACK,
//         0/42 machines have production_targets and only ~4/42 have any
//         per-machine counts; the enterprise is deliberately EXCLUDED
//         from the machine-level set, so NO rollup grain computes their
//         tp=1 OEE. The provisioning matrix still CREATES the skeleton
//         hour/shift/day rows, which then sit at their default (0) and
//         are never updated. front4 renders each of those as a flat
//         "0%" OEE tile — a value that reads as "this machine ran at 0%
//         efficiency" when the truth is "this machine is not
//         individually metered".
//
// THE CORRECTION:
//   For a machine grain row whose enterprise is NOT in the machine-level
//   set, the honest value is NULL ("not metered"), NOT 0. This pass
//   writes NULL to oee/oee_a/oee_p/oee_q for exactly those rows. It is a
//   deliberate, documented divergence from prod's flat-0 (correctness
//   over byte-parity) scoped to the class of rows prod never meters —
//   it CANNOT touch a machine-metered enterprise (the gate excludes the
//   whole machine-level set), so a genuine 0% on a metered machine is
//   preserved. Line (tp=3) and sector (tp=2) grains are untouched.
//
//   GATE (the existing signal — no new heuristic): tp_equipment = 1 AND
//   id_enterprise NOT IN machineLevelEnterprises. This is the exact
//   complement of the shift grain's `tp=1 AND id_enterprise = ANY(set)`
//   inclusion selector, so the two passes partition the tp=1 universe
//   with no overlap: the shift grain COMPUTES the machine-metered half,
//   this pass NULLs the line-metered half.
//
//   IDEMPOTENT: the `oee IS NOT NULL OR ...` guard means a row is
//   touched at most once — after it is nulled it drops out of the
//   working set, so steady-state ticks update zero rows. Freshly
//   provisioned skeleton rows (hourly) are the only ongoing inflow.
//
// FULL per-machine OEE for line-metered tenants is DEFERRED: it requires
// the edge to meter per-machine (emit per-machine count topics) and the
// enterprise to be added to ROLLUP_MACHINE_LEVEL_ENTERPRISES. Until
// then, "not metered" is the correct machine-tile state.
//
// GUARDRAIL STATEMENT: UPDATEs the equipment machine grain tables by
// (id_equipment, ts_value), setting only the four OEE columns to NULL.
// No PO tables; no time/count/state columns touched.
package rollup

import (
	"context"
	"fmt"

	"github.com/packiot/packiot-stack-alpha/services/oeecloud-worker/internal/flows"
)

// The equipment machine grain tables that back the per-machine OEE
// tiles. All seven carry oee/oee_a/oee_p/oee_q (verified against
// edge-api/schema.sql). Area/site tiers and the PO×shift join
// (equipment_runtime_shift_job) are intentionally excluded — they are
// not per-machine tiles.
var unmeteredMachineTables = []string{
	"equipment_runtime_1hour",
	"equipment_runtime_1day",
	"equipment_runtime_1week",
	"equipment_runtime_1month",
	"equipment_runtime_shift",
	"equipment_runtime_shift_1week",
	"equipment_runtime_shift_1month",
}

// %[1]s = event schema (grain tables), %[2]s = reference schema
// (equipments), %[3]s = table name. $1 = machineLevelEnterprises.
//
// Window: ts_value >= now()-90d bounds the scan to the tiles that can
// actually be viewed (current + recent buckets) while still catching
// the whole visible history; no upper bound so forward-provisioned
// buckets are corrected too. The idempotency predicate keeps every
// tick after the first cheap.
const unmeteredNullSQL = `
	UPDATE %[1]s.%[3]s e SET
	       oee = NULL, oee_a = NULL, oee_p = NULL, oee_q = NULL
	  FROM %[2]s.equipments q
	 WHERE e.id_equipment = q.id_equipment
	   AND q.tp_equipment = 1
	   AND NOT (q.id_enterprise = ANY($1))
	   AND e.ts_value >= now() - interval '90 days'
	   AND (e.oee IS NOT NULL OR e.oee_a IS NOT NULL
	        OR e.oee_p IS NOT NULL OR e.oee_q IS NOT NULL)`

// RunUnmetered nulls the OEE columns of every line-metered machine grain
// row for one destination — one tx, serialized against provision on the
// shared runtime advisory lock (it writes the same grain tables). Skips
// the tick (non-blocking) if provision holds the lock, like the other
// grain passes. Returns the total rows corrected across all tables.
func RunUnmetered(ctx context.Context, d flows.Dest, machineLevelEnterprises []int) (int64, error) {
	tx, err := d.Pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)
	if got, err := tryRuntimeLock(ctx, tx, d.Name); err != nil {
		return 0, fmt.Errorf("advisory try-lock: %w", err)
	} else if !got {
		return 0, tx.Commit(ctx)
	}
	var total int64
	for _, tbl := range unmeteredMachineTables {
		tag, err := tx.Exec(ctx, fmt.Sprintf(unmeteredNullSQL, d.EvSchema, d.RefSchema, tbl), machineLevelEnterprises)
		if err != nil {
			return 0, fmt.Errorf("unmetered %s: %w", tbl, err)
		}
		total += tag.RowsAffected()
	}
	return total, tx.Commit(ctx)
}

// UnmeteredStatementsForParity exposes the per-table statements (single
// source) for the golden fixture test.
func UnmeteredStatementsForParity(evSchema, refSchema string) []struct{ Name, SQL string } {
	out := make([]struct{ Name, SQL string }, 0, len(unmeteredMachineTables))
	for _, tbl := range unmeteredMachineTables {
		out = append(out, struct{ Name, SQL string }{tbl, fmt.Sprintf(unmeteredNullSQL, evSchema, refSchema, tbl)})
	}
	return out
}
