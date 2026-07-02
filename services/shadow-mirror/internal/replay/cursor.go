package replay

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

const cursorSource = "shadow-mirror"

// EnsureCursor returns the current cursor value, seeding a row if none
// exists. Reuses the mirror_replay_cursor table via a distinct source
// key so shadow-mirror and mirror-worker don't collide.
//
// First-run behavior: seeds cursor at the CURRENT MAX(id_user_logs) so
// we don't try to replay years of history on cold start. Better a fresh
// window than a giant catch-up storm. Operators can manually reset the
// cursor if they want a specific replay window.
func EnsureCursor(ctx context.Context, pool *pgxpool.Pool) (int64, error) {
	var existing int64
	err := pool.QueryRow(ctx,
		`SELECT last_log_id FROM mirror_replay_cursor WHERE source = $1`,
		cursorSource).Scan(&existing)
	if err == nil {
		return existing, nil
	}
	// No row → seed at current max.
	var maxID int64
	if err := pool.QueryRow(ctx,
		`SELECT COALESCE(MAX(id_user_logs), 0) FROM user_logs`).Scan(&maxID); err != nil {
		return 0, fmt.Errorf("seed cursor: read max id: %w", err)
	}
	if _, err := pool.Exec(ctx,
		`INSERT INTO mirror_replay_cursor (source, last_log_id, last_run_at)
		 VALUES ($1, $2, now())
		 ON CONFLICT (source) DO NOTHING`,
		cursorSource, maxID); err != nil {
		return 0, fmt.Errorf("seed cursor: insert: %w", err)
	}
	return maxID, nil
}

// AdvanceCursor moves the cursor forward. Idempotent: only writes if
// toID > current.
func AdvanceCursor(ctx context.Context, pool *pgxpool.Pool, toID int64) error {
	_, err := pool.Exec(ctx,
		`UPDATE mirror_replay_cursor
		    SET last_log_id = $1, last_run_at = now()
		  WHERE source = $2
		    AND last_log_id < $1`,
		toID, cursorSource)
	return err
}

// FetchBatch reads up to `limit` rows with id_user_logs > cursor.
// Returns rows ordered ascending so the cursor can advance
// deterministically.
func FetchBatch(ctx context.Context, pool *pgxpool.Pool, cursor int64, limit int) ([]UserLog, error) {
	rows, err := pool.Query(ctx,
		`SELECT id_user_logs, category, COALESCE(subcategory, ''), payload
		   FROM user_logs
		  WHERE id_user_logs > $1
		  ORDER BY id_user_logs ASC
		  LIMIT $2`,
		cursor, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]UserLog, 0, limit)
	for rows.Next() {
		var u UserLog
		if err := rows.Scan(&u.ID, &u.Category, &u.Subcategory, &u.Payload); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}
