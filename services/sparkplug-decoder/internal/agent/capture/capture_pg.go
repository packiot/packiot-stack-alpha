// capture_pg.go — the pgx-backed Sink for ADR-0045 Phase-2b capture. It upserts
// buffered observation deltas into capture_observations, reusing the SAME pgxpool
// the register loader / descriptor-status read use (register_pg.go, descriptor_pg.go)
// — never a second pool.
//
// The upsert folds each interval's delta into the persistent row: observed_count
// SUMS, first_seen_ts pins to the EARLIEST sighting, last_seen_ts widens to the
// LATEST. capture_observations is agent-written / edge-api-read (Phase-2b-api),
// the same ownership shape as packml_register. Every failure mode is a logged
// drop upstream (Recorder.Flush) — this layer only reports the error.
package capture

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PGSink upserts observation deltas over an existing pool.
type PGSink struct {
	pool *pgxpool.Pool
}

// NewPGSink builds a sink over an existing pool (the register pool — do not open
// a second one).
func NewPGSink(pool *pgxpool.Pool) *PGSink { return &PGSink{pool: pool} }

// compile-time assertion.
var _ Sink = (*PGSink)(nil)

const upsertSQL = `
INSERT INTO capture_observations
    (id_enterprise, topic, count_index, metric_suffix, first_seen_ts, last_seen_ts, observed_count)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (id_enterprise, topic, count_index) DO UPDATE SET
    first_seen_ts  = LEAST(capture_observations.first_seen_ts, EXCLUDED.first_seen_ts),
    last_seen_ts   = GREATEST(capture_observations.last_seen_ts, EXCLUDED.last_seen_ts),
    observed_count = capture_observations.observed_count + EXCLUDED.observed_count,
    metric_suffix  = EXCLUDED.metric_suffix
`

// Upsert writes all deltas in one batched round-trip. A batch keeps the DB touch
// cheap (buffer/flush discipline) while staying a single failure unit — a
// partial write is not possible per-row, and the whole batch is dropped-with-log
// on error (Recorder.Flush). An empty slice is a no-op.
func (s *PGSink) Upsert(ctx context.Context, enterpriseID int, deltas []Delta) error {
	if len(deltas) == 0 {
		return nil
	}
	batch := &pgx.Batch{}
	for _, d := range deltas {
		batch.Queue(upsertSQL,
			enterpriseID, d.Topic, d.CountIndex, d.MetricSuffix,
			d.FirstSeen, d.LastSeen, d.Count)
	}
	br := s.pool.SendBatch(ctx, batch)
	defer br.Close()
	for range deltas {
		if _, err := br.Exec(); err != nil {
			return fmt.Errorf("capture upsert (ent %d): %w", enterpriseID, err)
		}
	}
	return nil
}
