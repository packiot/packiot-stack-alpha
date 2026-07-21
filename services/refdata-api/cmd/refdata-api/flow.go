// flow.go — ADR-0032 Step 1: the F1↔F3 read-plane flow-routing switch.
//
// WHY THIS EXISTS
// ───────────────
// ADR-0032 collapses the staging three-flow parallel-run to the refactored
// flow (F3). Its load-bearing prerequisite (§5.1) is re-pointing THIS read
// plane from F1 (`packiot.public`) to F3 (`packiot_shadow.public`) — but F3's
// schema is intentionally divergent (ADR-0014), so it is NOT a connection-string
// swap. This switch makes the re-point:
//
//   - ADDITIVE — a single env, `REFDATA_FLOW`, selects the target. It defaults
//     to `f1`, so merging this changes NOTHING: refdata still reads `packiot`
//     via the existing pgbouncer pool with the existing SQL. The f3 path is
//     built and testable but dormant until the env is flipped (staging only).
//   - REVERSIBLE — flip the env back to `f1` and redeploy; nothing else moves.
//
// TWO THINGS THE SWITCH CONTROLS (per ADR-0032 §6 Step 1):
//
//  1. THE DB TARGET. f1 → dbname `packiot` (F1) via pgbouncer's `packiot` pool;
//     f3 → dbname `packiot_shadow` (F3) via pgbouncer's NEW `packiot_shadow`
//     pool (added by the sibling devops change on
//     feat/adr0032-step1-pgbouncer-grafana). main.go builds its DSN from
//     activeFlow.dbName instead of a hardcoded DB_NAME.
//
//  2. THE PER-DATASET SQL VARIANT. Each dataset/endpoint MAY carry an `sqlF3`
//     that overrides its F1 `sql` when the flow is f3 (activeSQL below). This is
//     the seam for schema divergence: if a backing object is RENAMED in F3
//     (e.g. the rename-map's future `ca_*`→`cagg_*` unification), the f3 SQL
//     names the new object while F1 SQL stays byte-identical.
//
//     GROUND-TRUTH NOTE (live census, 2026-07-20 — see the parity harness
//     scripts/refdata-f3-parity-check.sh): today packiot_shadow's divergence
//     from packiot is ABSENCE, not RENAME. Every object that EXISTS in F3 keeps
//     its F1 name (h_piot_*, v_operator_*, agg_equipment_values_*), so NO
//     dataset currently needs a textual sqlF3 override — they are byte-identical
//     across flows. The gap is that ~31 of 33 analytics functions and several
//     config/report relations DO NOT EXIST in F3 yet (they are the
//     telemetry-compute DB, not the analytics DB). Those datasets are BLOCKED on
//     F3 until packiot_shadow's read layer is built out; sqlF3 cannot conjure a
//     missing object, so it stays empty for them (documented as blockers, not
//     invented). The field is the mechanism that will carry the ports when they
//     land — pre-wired so the eventual adaptation is a data change, not a
//     structural one.
package main

// flow is the read-plane target: F1 (operational DB) or F3 (refactored shadow).
type flow string

const (
	flowF1 flow = "f1" // packiot.public — the operational DB (default, unchanged)
	flowF3 flow = "f3" // packiot_shadow.public — the refactored end-state DB
)

// activeFlow is the process-global read target, resolved ONCE from REFDATA_FLOW
// at startup (main.go). The whole binary serves exactly one flow — there is no
// per-request flow selection (a request cannot name a flow any more than it can
// name a tenant), so a package var read at compile/handler-build time is the
// correct scope. Defaults to f1 so an unset/typo'd env is the safe legacy path.
var activeFlow = flowF1

// resolveFlow parses REFDATA_FLOW. Anything other than an explicit "f3" resolves
// to f1 — fail-safe: a typo can never silently point reads at the shadow DB.
func resolveFlow(raw string) flow {
	if raw == "f3" {
		return flowF3
	}
	return flowF1
}

// dbNameForFlow returns the database name the DSN targets for a flow. The names
// are env-overridable (DB_NAME for F1, DB_NAME_F3 for F3) so a non-standard
// staging bring-up can re-point either without a rebuild, but the defaults are
// the canonical pool names pgbouncer maps: `packiot` and `packiot_shadow`.
func dbNameForFlow(f flow) string {
	if f == flowF3 {
		return getenv("DB_NAME_F3", "packiot_shadow")
	}
	return getenv("DB_NAME", "packiot")
}
