package linkhealth

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"time"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

type memSink struct {
	mu    sync.Mutex
	rows  []Row
	fails int
}

func (m *memSink) Upsert(_ context.Context, rows []Row) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fails > 0 {
		m.fails--
		return errors.New("db down")
	}
	m.rows = append(m.rows, rows...)
	return nil
}

func (m *memSink) snapshot() []Row {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Row(nil), m.rows...)
}

func TestRecorderAggregatesPerMinute(t *testing.T) {
	sink := &memSink{fails: 1} // first flush fails: the aggregate must survive it
	r := New(sink, 20*time.Millisecond, nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { r.Run(ctx); close(done) }()

	base := time.Date(2026, 10, 1, 12, 0, 0, 0, time.UTC).UnixMilli()
	r.Observe(" bispharmastaging ", rawtag.Link{Endpoint: "L60", ScanTS: base + 1000, OK: false, Err: "timeout", LatencyMs: 5000})
	r.Observe("BISPHARMASTAGING", rawtag.Link{Endpoint: "L60", ScanTS: base + 6000, OK: false, Err: "refused", LatencyMs: 20})
	r.Observe("BISPHARMASTAGING", rawtag.Link{Endpoint: "L01", ScanTS: base + 2000, OK: true, LatencyMs: 40})
	r.Observe("BISPHARMASTAGING", rawtag.Link{Endpoint: "L01", ScanTS: base + 61000, OK: true, LatencyMs: 30}) // next minute

	deadline := time.Now().Add(2 * time.Second)
	for len(sink.snapshot()) < 3 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done

	got := map[string]Row{}
	for _, row := range sink.snapshot() {
		got[row.Endpoint+row.Minute.Format("15:04")] = row
	}
	l60 := got["L6012:00"]
	if l60.Tenant != "BISPHARMASTAGING" || l60.FailTicks != 2 || l60.OKTicks != 0 || l60.LastError != "refused" || l60.MaxMs != 5000 {
		t.Fatalf("L60 row = %+v", l60)
	}
	if got["L0112:00"].OKTicks != 1 || got["L0112:01"].OKTicks != 1 {
		t.Fatalf("L01 rows = %+v / %+v", got["L0112:00"], got["L0112:01"])
	}
}

func TestObserveNeverBlocks(t *testing.T) {
	r := New(&memSink{}, time.Hour, nil, nil, slog.New(slog.NewTextHandler(io.Discard, nil)))
	for i := 0; i < 10000; i++ { // no Run loop draining: the queue fills, Observe must still return
		r.Observe("G", rawtag.Link{Endpoint: "E", ScanTS: 1, OK: true})
	}
	var nilRec *Recorder
	nilRec.Observe("G", rawtag.Link{}) // nil-safe
}
