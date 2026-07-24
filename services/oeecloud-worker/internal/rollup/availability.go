// availability.go — ADR-0037 finding (c) (medallion R3c): the single home for
// the "which downtime counts against Availability" classification rule shared by
// the base availability grains (hour.go, shift.go, backfill.go).
package rollup

// THE AVAILABILITY DENOMINATOR (Six Big Losses):
//
//	Availability = running_time / (ts_total − ts_planned)
//
// where ts_total is the bucket's elapsed wall-clock and ts_planned is the
// event-time that is SUBTRACTED from the clock as "planned production time
// removed" (a scheduled break, preventive maintenance — time the line was never
// expected to run). Anything left inside (ts_total − ts_planned) is production
// time the line WAS expected to run, so a stop there depresses Availability.
//
// FINDING (c): the 13-downtime-reasons seed flags CHANGEOVER as
// `planned_downtime=true` (and `change_over=true`). Under the default rule that
// makes changeover time land in ts_planned — i.e. REMOVED from the availability
// clock — so a machine that spends an hour in changeover reads the same
// Availability as one that ran the whole hour. In the Six-Big-Losses model,
// changeover/setup is an AVAILABILITY loss (unplanned-ish downtime WITHIN
// production time), not planned downtime removed from the clock. Removing it
// makes the loss the metric exists to expose invisible.
//
// plannedDowntimeExpr returns the SQL predicate that decides which event-time
// enters the ts_planned (planned-production-time) bucket:
//
//   - changeoverAvailability == false (default / prod-verbatim):
//     `ee.planned_downtime = true` — changeover, being planned_downtime=true,
//     is counted as planned and removed from the availability clock. This is
//     byte-identical to the ported prod function and is what the parity
//     accessors + `-tags golden` fixtures pin.
//
//   - changeoverAvailability == true (ADR-0037 (c) enabled):
//     `ee.planned_downtime = true AND ee.change_over IS DISTINCT FROM true` —
//     a genuine changeover (change_over=true) is EXCLUDED from ts_planned, so
//     its time stays inside (ts_total − ts_planned) and depresses Availability.
//     `IS DISTINCT FROM true` (not `= false`) is deliberate NULL-safety: a
//     planned event whose change_over is NULL must remain counted as planned —
//     only an explicit change_over=true is reclassified, the exact complement of
//     the ts_changeover CASE (`ee.change_over = true`). changeover_time is still
//     summed separately, so this only MOVES changeover from the planned bucket
//     into the availability-loss basis; it never changes the changeover report.
//
// The predicate is injected as a format arg into the base-grain event SQL, so
// the constant stays a single source of truth and the off-path is textually
// identical to today. The higher grains (day/week/month/entity, grains.go) SUM
// the already-classified available_time / planned_downtime / changeover_time
// columns from the base grains, so the reclassification propagates upward with
// no further change.
func plannedDowntimeExpr(changeoverAvailability bool) string {
	if changeoverAvailability {
		return "ee.planned_downtime = true AND ee.change_over IS DISTINCT FROM true"
	}
	return "ee.planned_downtime = true"
}
