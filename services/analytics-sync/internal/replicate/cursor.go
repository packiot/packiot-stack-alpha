package replicate

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The cursor lives in the DEST DB (packiot_analytics), NOT the source:
// legacy packiot40 is SELECT-only, so we cannot persist progress there.
// Same mirror_replay_cursor shape as the in-instance mirror, created
// on demand here since packiot_analytics has no such table yet.

const cursorDDL = `CREATE TABLE IF NOT EXISTS mirror_replay_cursor (
	source       text PRIMARY KEY,
	last_log_id  bigint NOT NULL,
	last_run_at  timestamptz NOT NULL DEFAULT now()
)`

// EnsureCursor returns the current cursor for source, seeding it on cold
// start just BELOW the first legacy row in the backfill window so the loop
// replays history forward then continues live. A pre-existing cursor is
// returned untouched (idempotent restarts). destPool = staging (cursor
// store); legacyPool = source (window probe, read-only).
func EnsureCursor(ctx context.Context, destPool, legacyPool *pgxpool.Pool, source string, srcEnterprise int, sinceStart time.Time) (int64, error) {
	if _, err := destPool.Exec(ctx, cursorDDL); err != nil {
		return 0, fmt.Errorf("ensure cursor table: %w", err)
	}
	var existing int64
	err := destPool.QueryRow(ctx,
		`SELECT last_log_id FROM mirror_replay_cursor WHERE source = $1`, source).Scan(&existing)
	if err == nil {
		return existing, nil
	}
	if err != pgx.ErrNoRows {
		return 0, fmt.Errorf("read cursor: %w", err)
	}

	// Cold start: seed just below the first row in the window.
	var minID, maxID int64
	if err := legacyPool.QueryRow(ctx,
		`SELECT COALESCE(MIN(id_user_logs),0), COALESCE(MAX(id_user_logs),0)
		   FROM user_logs
		  WHERE id_enterprise = $1 AND ts_log >= $2`,
		srcEnterprise, sinceStart).Scan(&minID, &maxID); err != nil {
		return 0, fmt.Errorf("seed probe: %w", err)
	}
	seed := int64(0)
	if minID > 0 {
		seed = minID - 1 // replay from the first windowed row inclusive
	} else {
		// No rows in the window — start live-only from the current tip.
		if err := legacyPool.QueryRow(ctx,
			`SELECT COALESCE(MAX(id_user_logs),0) FROM user_logs WHERE id_enterprise = $1`,
			srcEnterprise).Scan(&seed); err != nil {
			return 0, fmt.Errorf("seed tip: %w", err)
		}
	}
	if _, err := destPool.Exec(ctx,
		`INSERT INTO mirror_replay_cursor (source, last_log_id, last_run_at)
		 VALUES ($1, $2, now()) ON CONFLICT (source) DO NOTHING`,
		source, seed); err != nil {
		return 0, fmt.Errorf("seed insert: %w", err)
	}
	return seed, nil
}

// AdvanceCursor moves the cursor forward only.
func AdvanceCursor(ctx context.Context, destPool *pgxpool.Pool, source string, toID int64) error {
	_, err := destPool.Exec(ctx,
		`UPDATE mirror_replay_cursor SET last_log_id = $1, last_run_at = now()
		  WHERE source = $2 AND last_log_id < $1`,
		toID, source)
	return err
}

// UserLog is one legacy user_logs row for the polled enterprise.
type UserLog struct {
	ID          int64
	Category    string
	IDEquipment int
	Payload     json.RawMessage
}

// FetchBatch reads up to limit legacy rows for the polled enterprise with
// id_user_logs > cursor, ascending. Read-only against packiot40.
func FetchBatch(ctx context.Context, legacyPool *pgxpool.Pool, srcEnterprise int, cursor int64, limit int) ([]UserLog, error) {
	rows, err := legacyPool.Query(ctx,
		`SELECT id_user_logs, category, COALESCE(id_equipment,0), payload
		   FROM user_logs
		  WHERE id_enterprise = $1 AND id_user_logs > $2
		  ORDER BY id_user_logs ASC
		  LIMIT $3`,
		srcEnterprise, cursor, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]UserLog, 0, limit)
	for rows.Next() {
		var u UserLog
		if err := rows.Scan(&u.ID, &u.Category, &u.IDEquipment, &u.Payload); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}
