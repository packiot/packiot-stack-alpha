// Package verdict is the ADR-0022 V3 behavior-correctness acceptance
// suite — the second half of the flip-readiness verdict.
//
// The bake (ADR-0016) and its per-tenant convergence recording rule
// (monitoring/prometheus/rules.yml → bake_tenant_converged) answer
// "does F3 equal F1 for this tenant?" — DATA PARITY. That is necessary
// but has one blind spot: F1 and F3 can AGREE and both be WRONG (a
// shared bug in the ported compute would move both flows identically,
// and the comparator, which only diffs the two, would stay green).
//
// This suite closes that spot. It seeds KNOWN inputs into an ephemeral
// Postgres, runs the ACTUAL ported compute (the same
// rollup.*ForParity() statements the worker executes in production),
// and asserts the computed outputs are the RIGHT numbers — the OEE
// arithmetic derived independently in each scenario's comment, not
// reverse-engineered from a fixture. A wrong "expected" value would
// make the suite lie, so every expectation is shown as explicit
// A×P×Q (or availability) arithmetic next to the assertion.
//
// Relationship to internal/rollup/golden_test.go: that file is the
// REGRESSION harness (freezes the parity-proven SQL constants against
// hand-built fixtures, catching drift in the ported statements). This
// package is the ACCEPTANCE suite (asserts the domain math is correct
// end-to-end for a factory's core surfaces). Same ephemeral-PG
// approach, same `-tags golden` lane; different question. It reuses
// rollup's ForParity accessors as its single source of compute SQL —
// it does not copy any statement.
//
// Scenarios (each tenant-parameterized — run for enterprise 3 CPACK
// and 4 Incoplast):
//
//  1. OEE cascade at the SHIFT grain — a known production+downtime
//     scenario → the collapsed shift OEE equals A×P×Q computed by hand.
//  2. PO lifecycle — start→running→pause→finish attribution rolls up
//     into the right production_orders A/P/Q via the recalc consumer.
//  3. Downtime classification — the SAME physical downtime, classified
//     PLANNED vs UNPLANNED, yields the correct (differing) availability.
//
// Run: DATABASE_URL=postgres://… go test -tags golden ./internal/verdict
package verdict
