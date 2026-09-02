package replicate

// dlq.go — dead-letter queue for the cross-instance twin replicator.
//
// The main Loop advances the cursor on EVERY row so it can never wedge (a
// single poison row must not stall the twin). Before this, a dispatch that
// FAILED (returned a non-ErrSkip error) was logged and then silently dropped —
// the operator action it carried never reached the twin and there was no record
// or retry. Live example: order-changed / order-created-started hitting the
// production_orders_runtime no-overlap exclusion (SQLSTATE 23P01) during a
// window race — dozens of lost lifecycle actions.
//
// The DLQ closes that gap without changing the cursor-always-advances invariant:
//
//  1. On dispatch failure the Loop writes the row into mirror_replay_dlq
//     (source, source_log_id, category, payload, error) — then advances.
//  2. A bounded retrier (DLQRetrier) periodically re-fetches the legacy
//     user_log by id, re-dispatches it through the SAME handler set (so retried
//     rows take the identical, idempotent code path), and DELETEs the DLQ row on
//     success. On failure it bumps retry_attempts with exponential backoff; at
//     the cap the row stops re-driving but stays in the table for inspection.
//
// The table lives in the DEST DB (legacy packiot40 is SELECT-only) and is
// source-keyed, so the two replicator instances (legacy-cpack + legacy-sbxcpack)
// share it safely. Additive + reversible: a new table, no destructive writes.

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// dlqDDL creates the DLQ table on demand. Shape matches edge-node-red/db/
// 25-mirror-replay-schema.sql plus the retry_attempts / last_retry_at columns
// the retrier needs (mirror-worker-go carries the same two columns).
const dlqDDL = `CREATE TABLE IF NOT EXISTS mirror_replay_dlq (
	id             BIGSERIAL   PRIMARY KEY,
	source         text        NOT NULL,
	source_log_id  bigint      NOT NULL,
	category       text,
	subcategory    text,
	payload        jsonb,
	error          text        NOT NULL,
	retry_attempts int         NOT NULL DEFAULT 0,
	last_retry_at  timestamptz,
	created_at     timestamptz NOT NULL DEFAULT now()
)`

const dlqIndexDDL = `CREATE INDEX IF NOT EXISTS mirror_replay_dlq_source_idx
	ON mirror_replay_dlq (source, created_at DESC)`

// EnsureDLQ creates the DLQ table + index if absent. Called once at loop start
// (and idempotent). Failure here is returned so the caller can decide — but the
// loop treats a missing DLQ as fail-open (see writeDLQ) so capture is best
// effort and never wedges replay.
func EnsureDLQ(ctx context.Context, dst *pgxpool.Pool) error {
	if _, err := dst.Exec(ctx, dlqDDL); err != nil {
		return err
	}
	// Older deployments created the table without the retry columns — add them
	// idempotently so a shared table converges to the full shape.
	if _, err := dst.Exec(ctx,
		`ALTER TABLE mirror_replay_dlq
		   ADD COLUMN IF NOT EXISTS retry_attempts int NOT NULL DEFAULT 0,
		   ADD COLUMN IF NOT EXISTS last_retry_at  timestamptz`); err != nil {
		return err
	}
	_, err := dst.Exec(ctx, dlqIndexDDL)
	return err
}

// writeDLQ appends a failed row for retry + inspection. Best-effort: a failure
// to record (e.g. the table briefly missing) is logged, never propagated — the
// caller still advances the cursor.
func writeDLQ(ctx context.Context, dst *pgxpool.Pool, source string, u *UserLog, errMsg string, logger *slog.Logger) {
	_, err := dst.Exec(ctx,
		`INSERT INTO mirror_replay_dlq (source, source_log_id, category, payload, error)
		 VALUES ($1, $2, $3, $4::jsonb, $5)`,
		source, u.ID, u.Category, string(u.Payload), errMsg)
	if err != nil {
		logger.Warn("DLQ write failed (row not captured)",
			slog.Int64("id_user_log", u.ID), slog.String("category", u.Category), slog.String("err", err.Error()))
	}
}

// dlqRow is the slim projection the retrier needs.
type dlqRow struct {
	id          int64
	sourceLogID int64
	category    string
	attempts    int
}

// fetchRetriableDLQ returns rows under the attempt cap whose backoff window has
// elapsed. Backoff = (1 << retry_attempts) minutes on last_retry_at; a NULL
// last_retry_at (never retried) is immediately eligible.
const sqlFetchRetriableDLQ = `SELECT id, source_log_id, category, retry_attempts
		   FROM mirror_replay_dlq
		  WHERE source = $1 AND retry_attempts < $2
		    AND (last_retry_at IS NULL
		         OR last_retry_at + (interval '1 minute' * (1 << retry_attempts)) < now())
		  ORDER BY id
		  LIMIT $3`

func fetchRetriableDLQ(ctx context.Context, dst *pgxpool.Pool, source string, maxAttempts, limit int) ([]dlqRow, error) {
	rows, err := dst.Query(ctx, sqlFetchRetriableDLQ, source, maxAttempts, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []dlqRow
	for rows.Next() {
		var r dlqRow
		if err := rows.Scan(&r.id, &r.sourceLogID, &r.category, &r.attempts); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// DLQRetrier re-drives captured rows through the live dispatcher. Reuses the
// exact handler set so a retried row is byte-for-byte the same replay as a
// first attempt — no shadow logic to drift.
type DLQRetrier struct {
	legacy *pgxpool.Pool
	dst    *pgxpool.Pool
	r      *Resolver
	d      *Dispatcher
	cfg    *Config
	m      DLQMetrics
	logger *slog.Logger
}

// DLQMetrics is the counter surface the retrier bumps. *metrics.Metrics
// satisfies it; nil is tolerated (tests).
type DLQMetrics interface {
	IncDLQRetried(outcome string)
	SetDLQDepth(n int64)
}

type noopDLQMetrics struct{}

func (noopDLQMetrics) IncDLQRetried(string) {}
func (noopDLQMetrics) SetDLQDepth(int64)    {}

func NewDLQRetrier(legacy, dst *pgxpool.Pool, r *Resolver, d *Dispatcher, cfg *Config, m DLQMetrics, logger *slog.Logger) *DLQRetrier {
	if m == nil {
		m = noopDLQMetrics{}
	}
	return &DLQRetrier{legacy: legacy, dst: dst, r: r, d: d, cfg: cfg, m: m, logger: logger}
}

// RunForever runs one pass at startup then on DLQRetryIntervalSec. Returns when
// ctx is cancelled. Inert when DLQRetryEnabled=false.
func (rt *DLQRetrier) RunForever(ctx context.Context) error {
	if !rt.cfg.DLQRetryEnabled {
		rt.logger.Info("DLQ retry disabled (DLQ_RETRY_ENABLED=false)")
		<-ctx.Done()
		return ctx.Err()
	}
	interval := time.Duration(rt.cfg.DLQRetryIntervalSec) * time.Second
	rt.logger.Info("DLQ retry started",
		slog.Int("interval_sec", rt.cfg.DLQRetryIntervalSec),
		slog.Int("max_attempts", rt.cfg.DLQRetryMaxAttempts),
		slog.Int("batch_size", rt.cfg.DLQRetryBatchSize),
		slog.String("source", rt.cfg.CursorSource))
	rt.runOnce(ctx)
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			rt.runOnce(ctx)
		}
	}
}

func (rt *DLQRetrier) runOnce(ctx context.Context) {
	if n, err := countDLQ(ctx, rt.dst, rt.cfg.CursorSource); err == nil {
		rt.m.SetDLQDepth(n)
	}
	rows, err := fetchRetriableDLQ(ctx, rt.dst, rt.cfg.CursorSource, rt.cfg.DLQRetryMaxAttempts, rt.cfg.DLQRetryBatchSize)
	if err != nil {
		rt.logger.Warn("DLQ retry: fetch failed", slog.String("err", err.Error()))
		return
	}
	if len(rows) == 0 {
		return
	}
	var ok, failed, gone int
	for _, row := range rows {
		switch rt.retryOne(ctx, row) {
		case "succeeded":
			ok++
			rt.m.IncDLQRetried("succeeded")
		case "gone":
			gone++
			rt.m.IncDLQRetried("gone")
		default:
			failed++
			rt.m.IncDLQRetried("failed")
		}
	}
	rt.logger.Info("DLQ retry pass done",
		slog.Int("examined", len(rows)), slog.Int("succeeded", ok),
		slog.Int("failed", failed), slog.Int("gone", gone))
}

// retryOne re-fetches the legacy user_log and re-dispatches it. On success the
// DLQ row is deleted; on failure retry_attempts is bumped (backoff slides); if
// the legacy row is gone it is retired to the cap so it stops re-driving.
func (rt *DLQRetrier) retryOne(ctx context.Context, row dlqRow) string {
	u, found, err := FetchUserLogByID(ctx, rt.legacy, rt.cfg.SrcEnterprise, row.sourceLogID)
	if err != nil {
		rt.logger.Warn("DLQ retry: legacy fetch failed — retry next pass",
			slog.Int64("dlq_id", row.id), slog.Int64("source_log_id", row.sourceLogID), slog.String("err", err.Error()))
		_ = markDLQRetried(ctx, rt.dst, row.id)
		return "failed"
	}
	if !found {
		rt.logger.Warn("DLQ retry: legacy user_log gone — retiring",
			slog.Int64("dlq_id", row.id), slog.Int64("source_log_id", row.sourceLogID))
		_ = retireDLQ(ctx, rt.dst, row.id, rt.cfg.DLQRetryMaxAttempts)
		return "gone"
	}
	skipped, derr := rt.d.Dispatch(ctx, rt.legacy, rt.dst, rt.r, u)
	if derr != nil {
		rt.logger.Warn("DLQ retry failed — backoff",
			slog.Int64("dlq_id", row.id), slog.Int64("source_log_id", row.sourceLogID),
			slog.String("category", row.category), slog.Int("prior_attempts", row.attempts), slog.String("err", derr.Error()))
		_ = markDLQRetried(ctx, rt.dst, row.id)
		return "failed"
	}
	// Success (applied or cleanly skipped) — remove the row.
	if err := deleteDLQ(ctx, rt.dst, row.id); err != nil {
		rt.logger.Warn("DLQ retry: delete failed (will re-select)", slog.Int64("dlq_id", row.id), slog.String("err", err.Error()))
		return "failed"
	}
	rt.logger.Info("DLQ retry succeeded — row cleared",
		slog.Int64("dlq_id", row.id), slog.Int64("source_log_id", row.sourceLogID),
		slog.String("category", row.category), slog.Bool("skipped", skipped))
	return "succeeded"
}

func countDLQ(ctx context.Context, dst *pgxpool.Pool, source string) (int64, error) {
	var n int64
	err := dst.QueryRow(ctx, `SELECT count(*) FROM mirror_replay_dlq WHERE source = $1`, source).Scan(&n)
	return n, err
}

func deleteDLQ(ctx context.Context, dst *pgxpool.Pool, id int64) error {
	_, err := dst.Exec(ctx, `DELETE FROM mirror_replay_dlq WHERE id = $1`, id)
	return err
}

func markDLQRetried(ctx context.Context, dst *pgxpool.Pool, id int64) error {
	_, err := dst.Exec(ctx,
		`UPDATE mirror_replay_dlq SET retry_attempts = retry_attempts + 1, last_retry_at = now() WHERE id = $1`, id)
	return err
}

func retireDLQ(ctx context.Context, dst *pgxpool.Pool, id int64, cap int) error {
	_, err := dst.Exec(ctx,
		`UPDATE mirror_replay_dlq SET retry_attempts = GREATEST(retry_attempts, $2), last_retry_at = now() WHERE id = $1`, id, cap)
	return err
}

// FetchUserLogByID re-reads a single legacy user_log for the DLQ retrier. Scoped
// to the source enterprise so a DLQ row can never re-drive a foreign tenant's row.
func FetchUserLogByID(ctx context.Context, legacy *pgxpool.Pool, srcEnterprise int, id int64) (*UserLog, bool, error) {
	var u UserLog
	err := legacy.QueryRow(ctx,
		`SELECT id_user_logs, category, COALESCE(id_equipment,0), payload
		   FROM user_logs WHERE id_user_logs = $1 AND id_enterprise = $2`,
		id, srcEnterprise).Scan(&u.ID, &u.Category, &u.IDEquipment, &u.Payload)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	return &u, true, nil
}
