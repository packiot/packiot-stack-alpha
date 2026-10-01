// Package linkhealth records per-PLC connection health reported by the edge
// reader (rawtag.Link on /v1/tags) as one row per tenant × endpoint × minute in
// silver.plc_link_minutes (2026-10-01).
//
// Why: Bispharma's counters report only on change, and before this the reader
// posted nothing when a PLC read failed — so "line stopped", "PLC unreachable"
// and "box dead" all reached the cloud as the same silence, and the count-silence
// deriver minted stops for all three. A minute with ok_ticks > 0 proves the PLC
// was being read; a minute with only fail_ticks — or no row at all once
// monitoring has started — is NO DATA, which availability excludes instead of
// counting as a stop.
//
// The ingest hot path only enqueues (non-blocking; a full queue drops + counts);
// a single goroutine aggregates and flushes additive upserts. Replayed spool
// batches carry their original scan_ts, so an uplink outage fills back in.
package linkhealth

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// Row is one aggregated tenant × endpoint × minute.
type Row struct {
	Tenant    string // upper(group) == core.client_descriptors.tenant_code
	Endpoint  string
	Minute    time.Time
	OKTicks   int
	FailTicks int
	LastError string
	MaxMs     int
}

// Sink persists aggregated rows (additively).
type Sink interface {
	Upsert(ctx context.Context, rows []Row) error
}

type key struct {
	tenant, endpoint string
	minute           int64
}

type obs struct {
	tenant string
	link   rawtag.Link
}

// Recorder is safe for concurrent Observe calls.
type Recorder struct {
	ch      chan obs
	sink    Sink
	every   time.Duration
	dropped prometheus.Counter
	failed  prometheus.Counter
	logger  *slog.Logger
}

// New builds a recorder; dropped/failed may be nil.
func New(sink Sink, every time.Duration, dropped, failed prometheus.Counter, logger *slog.Logger) *Recorder {
	if every <= 0 {
		every = 15 * time.Second
	}
	return &Recorder{ch: make(chan obs, 4096), sink: sink, every: every, dropped: dropped, failed: failed, logger: logger}
}

// Observe enqueues one link report. Never blocks.
func (r *Recorder) Observe(group string, l rawtag.Link) {
	if r == nil {
		return
	}
	select {
	case r.ch <- obs{tenant: strings.ToUpper(strings.TrimSpace(group)), link: l}:
	default:
		if r.dropped != nil {
			r.dropped.Inc()
		}
	}
}

// Run aggregates and flushes until ctx ends (then flushes once more).
func (r *Recorder) Run(ctx context.Context) {
	t := time.NewTicker(r.every)
	defer t.Stop()
	agg := map[key]*Row{}
	flush := func(fctx context.Context) {
		if len(agg) == 0 {
			return
		}
		rows := make([]Row, 0, len(agg))
		for _, v := range agg {
			rows = append(rows, *v)
		}
		if err := r.sink.Upsert(fctx, rows); err != nil {
			// Best-effort evidence: keep the aggregate for the next flush rather
			// than lose it, unless it has grown unreasonably (DB down for long).
			if r.failed != nil {
				r.failed.Inc()
			}
			r.logger.Warn("plc link health flush failed", "rows", len(rows), "err", err)
			if len(agg) > 200000 {
				agg = map[key]*Row{}
			}
			return
		}
		agg = map[key]*Row{}
	}
	for {
		select {
		case <-ctx.Done():
			fctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			flush(fctx)
			cancel()
			return
		case o := <-r.ch:
			add(agg, o)
		case <-t.C:
			fctx, cancel := context.WithTimeout(ctx, 10*time.Second)
			flush(fctx)
			cancel()
		}
	}
}

func add(agg map[key]*Row, o obs) {
	m := time.UnixMilli(o.link.ScanTS).UTC().Truncate(time.Minute)
	k := key{o.tenant, o.link.Endpoint, m.Unix()}
	row, ok := agg[k]
	if !ok {
		row = &Row{Tenant: o.tenant, Endpoint: o.link.Endpoint, Minute: m}
		agg[k] = row
	}
	if o.link.OK {
		row.OKTicks++
	} else {
		row.FailTicks++
		if o.link.Err != "" {
			row.LastError = o.link.Err
		}
	}
	if o.link.LatencyMs > row.MaxMs {
		row.MaxMs = o.link.LatencyMs
	}
}

// PGSink writes to silver.plc_link_minutes. The tenant is resolved to its
// enterprise through core.client_descriptors.tenant_code INSIDE the statement,
// so a group with no descriptor writes nothing (tenant-safe by construction).
type PGSink struct{ pool *pgxpool.Pool }

func NewPGSink(pool *pgxpool.Pool) *PGSink { return &PGSink{pool: pool} }

const upsertSQL = `
INSERT INTO silver.plc_link_minutes AS t
    (id_enterprise, endpoint, ts_minute, ok_ticks, fail_ticks, last_error, max_latency_ms, updated_at)
SELECT cd.id_enterprise, $2, $3, $4, $5, NULLIF($6, ''), $7, now()
  FROM core.client_descriptors cd
 WHERE upper(cd.tenant_code) = $1
ON CONFLICT (id_enterprise, endpoint, ts_minute) DO UPDATE SET
    ok_ticks       = t.ok_ticks + EXCLUDED.ok_ticks,
    fail_ticks     = t.fail_ticks + EXCLUDED.fail_ticks,
    last_error     = COALESCE(EXCLUDED.last_error, t.last_error),
    max_latency_ms = GREATEST(t.max_latency_ms, EXCLUDED.max_latency_ms),
    updated_at     = now()`

func (s *PGSink) Upsert(ctx context.Context, rows []Row) error {
	b := &pgx.Batch{}
	for _, r := range rows {
		b.Queue(upsertSQL, r.Tenant, r.Endpoint, r.Minute, r.OKTicks, r.FailTicks, r.LastError, r.MaxMs)
	}
	br := s.pool.SendBatch(ctx, b)
	defer br.Close()
	for range rows {
		if _, err := br.Exec(); err != nil {
			return err
		}
	}
	return nil
}
