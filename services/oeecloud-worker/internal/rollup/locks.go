package rollup

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// tryRuntimeLock attempts the per-dest runtime advisory lock WITHOUT blocking.
//
// The rollup, the runtime backfill, and the provision all serialize on the same
// per-dest key (hashtextextended("<dest>:runtime")) so they never write the same
// grain rows concurrently. Provision holds it (session-scoped, blocking) for the
// whole provisioning pass — which can run for minutes when the DB is under I/O
// pressure. If the live rollup took the lock with the BLOCKING pg_advisory_xact_lock,
// that wait is capped by the pool's statement_timeout (120s on the pgbouncer'd main
// pool) → the tick dies with "canceling statement due to statement timeout" and
// commits nothing, exactly when the system is already struggling.
//
// Non-blocking acquisition degrades gracefully instead: if another holder has the
// lock, the caller commits-and-skips this tick and retries on the next one. The
// recalc_needed rows stay flagged, so nothing is lost — the work simply defers to a
// tick where the lock is free. This is the same discipline backfill.go already uses
// (pg_try_advisory_xact_lock); this helper unifies it for the live grain rollups.
//
// Returns (true, nil) when the lock is held by this transaction, (false, nil) when
// another holder has it, or (_, err) on a query error.
func tryRuntimeLock(ctx context.Context, tx pgx.Tx, destName string) (bool, error) {
	var got bool
	err := tx.QueryRow(ctx,
		`SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))`, destName+":runtime").Scan(&got)
	return got, err
}
