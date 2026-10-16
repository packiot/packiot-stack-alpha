package rollupshadow

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/flows"
)

// recordSQL writes the hourly shadow diff into ops.data_invariant_result (R1 twin vs truth, R2 cagg
// vs truth; db/migrations/t-ts-b1-shadow-invariant). %s = the quoted silver schema.
const recordSQL = `SELECT %s.rollup_shadow_record($1, $2)`

// recordAfter: the previous hour is recorded this far past the top of the hour, so its late rows
// have been invalidated and drained by a few ticks first.
const recordAfter = 7 * time.Minute

// RecordQuery renders the record statement for a schema.
func RecordQuery(silverSchema string) string {
	return fmt.Sprintf(recordSQL, pgx.Identifier{silverSchema}.Sanitize())
}

// HourToRecord returns the complete hour to record at `now`, and false when the hour `last` (the
// top of the hour already recorded) is still current or it is too early in the hour.
func HourToRecord(now, last time.Time) (from, to time.Time, ok bool) {
	top := now.UTC().Truncate(time.Hour)
	if now.UTC().Sub(top) < recordAfter || !top.After(last) {
		return time.Time{}, time.Time{}, false
	}
	return top.Add(-time.Hour), top, true
}

// RecordHour writes the shadow-diff invariants for [from, to) and returns the rows written.
func RecordHour(ctx context.Context, d flows.Dest, from, to time.Time) (int32, error) {
	var n int32
	if err := d.Pool.QueryRow(ctx, RecordQuery(d.SilverSchema), from, to).Scan(&n); err != nil {
		return 0, fmt.Errorf("rollup_shadow_record: %w", err)
	}
	return n, nil
}
