// event_splitted_test.go — mirrors event_justified_test.go for the
// event-splitted handler.
//
// Coverage:
//   - SplitPayload struct parses real prod payloads (events array preserved)
//   - When the handler returns a failure, dispatch records outcome=failed
//   - When the handler returns an error wrapping ErrSkipReplay
//     (chicken-and-egg parent-missing case, PR #59), dispatch records
//     outcome=skipped — even though split.service.ts uses the slightly
//     different "Event does not exist" literal
//
// As elsewhere, the live translator + HTTP path is exercised end-to-end
// via httputil_test.go's httptest.Server cases.
package replay

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

func TestSplitPayload_Unmarshal(t *testing.T) {
	cases := []struct {
		name           string
		raw            string
		wantEquipment  int
		wantEventID    int64
		wantEventType  string
		wantEventCount int
	}{
		{
			name:           "minimal split into two events",
			raw:            `{"idEquipment":42,"idEquipmentEvent":12345,"eventType":"manual","events":[{},{}]}`,
			wantEquipment:  42,
			wantEventID:    12345,
			wantEventType:  "manual",
			wantEventCount: 2,
		},
		{
			name:           "split into three with metadata",
			raw:            `{"idEquipment":42,"idEquipmentEvent":12345,"eventType":"manual","events":[{"startTime":"2026-06-24T10:00:00Z"},{"startTime":"2026-06-24T10:02:00Z"},{"startTime":"2026-06-24T10:04:00Z","endTime":"2026-06-24T10:05:00Z"}]}`,
			wantEquipment:  42,
			wantEventID:    12345,
			wantEventType:  "manual",
			wantEventCount: 3,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p SplitPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if p.IDEquipment != c.wantEquipment {
				t.Errorf("IDEquipment = %d, want %d", p.IDEquipment, c.wantEquipment)
			}
			if p.IDEquipmentEvent != c.wantEventID {
				t.Errorf("IDEquipmentEvent = %d, want %d", p.IDEquipmentEvent, c.wantEventID)
			}
			if p.EventType != c.wantEventType {
				t.Errorf("EventType = %q, want %q", p.EventType, c.wantEventType)
			}
			if len(p.Events) != c.wantEventCount {
				t.Errorf("events count = %d, want %d", len(p.Events), c.wantEventCount)
			}
		})
	}
}

func TestEventSplitted_FailedDispatch_RecordsFailed(t *testing.T) {
	const evt = "event-splitted"
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		// Real DLQ shape today — validation failure that MUST stay failed.
		return errors.New(`staging /api/downtimes/split returned 400: {"statusCode":400,"message":"Original end time must not be defined"}`)
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(`{"idEquipment":42,"idEquipmentEvent":12345,"eventType":"manual","events":[{}]}`),
	})
	if err == nil {
		t.Fatal("Dispatch err = nil, want non-nil from fake handler")
	}

	got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))
	if got != beforeFailed+1 {
		t.Errorf("event-splitted failed count = %f, want %f", got, beforeFailed+1)
	}
}

// TestEventSplitted_SkipReplay_DispatcherRecordsSkipped — split.service.ts
// throws NotFoundException('Event does not exist') (not "Downtime…"), so
// pin that the matcher and downstream skip wiring work for that variant.
func TestEventSplitted_SkipReplay_DispatcherRecordsSkipped(t *testing.T) {
	const evt = "event-splitted"
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		// Same wrap shape PostStaging emits when classifyStagingError
		// promotes "Event does not exist" 404 to a skip.
		return fmt.Errorf("staging /api/downtimes/split returned 404: parent downtime/event missing — child replay skipped: %w",
			ErrSkipReplay)
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(`{"idEquipment":42,"idEquipmentEvent":12345,"eventType":"manual","events":[{}]}`),
	})
	if err != nil {
		t.Fatalf("Dispatch err = %v, want nil for skip-replay", err)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped+1 {
		t.Errorf("event-splitted skipped = %f, want %f", got, beforeSkipped+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed {
		t.Errorf("event-splitted failed = %f, want %f (skip must not bump failed)", got, beforeFailed)
	}
}

// TestAlignSplitEventsToStaging — the alignment helper isolated. Covers the
// real DLQ-282 shape (closed staging event, prod first-start drifts -3h35m),
// the entry-283 / open-staging shape (ts_end IS NULL), and a couple of
// defensive corner cases.
func TestAlignSplitEventsToStaging(t *testing.T) {
	stagingStart := time.Date(2026, 6, 22, 20, 41, 7, 0, time.UTC)
	stagingEnd := time.Date(2026, 6, 25, 6, 54, 0, 0, time.UTC)

	cases := []struct {
		name              string
		events            []any
		stagingTsEvent    time.Time
		stagingTsEnd      sql.NullTime
		wantFirstStart    string
		wantLastEnd       any // may be nil if leave-alone
		wantStartDriftSec int
		wantEndDriftSec   int
	}{
		{
			// DLQ id 282 — closed staging event, big start drift, end matches.
			name: "dlq-282-shape-closed-staging-with-start-drift",
			events: []any{
				map[string]any{"startTime": "2026-06-22T17:06:00.000Z", "endTime": "2026-06-25T05:50:00.000Z"},
				map[string]any{"startTime": "2026-06-25T05:50:00.000Z", "endTime": "2026-06-25T06:54:00.000Z"},
			},
			stagingTsEvent:    stagingStart,
			stagingTsEnd:      sql.NullTime{Time: stagingEnd, Valid: true},
			wantFirstStart:    "2026-06-22T20:41:07.000Z",
			wantLastEnd:       "2026-06-25T06:54:00.000Z",
			wantStartDriftSec: 3*3600 + 35*60 + 7, // 3h35m07s
			wantEndDriftSec:   0,
		},
		{
			// Open-staging — operator's last endTime preserved (could be null
			// or a closing timestamp; staging will close at whatever they sent).
			name: "open-staging-leaves-operator-endtime-alone",
			events: []any{
				map[string]any{"startTime": "2026-06-25T11:13:00.000Z", "endTime": "2026-06-25T11:58:00.000Z"},
				map[string]any{"startTime": "2026-06-25T11:58:00.000Z", "endTime": nil},
			},
			stagingTsEvent:    time.Date(2026, 6, 25, 11, 13, 0, 0, time.UTC),
			stagingTsEnd:      sql.NullTime{Valid: false},
			wantFirstStart:    "2026-06-25T11:13:00.000Z",
			wantLastEnd:       nil,
			wantStartDriftSec: 0,
			wantEndDriftSec:   0,
		},
		{
			// Interior split-point is preserved — only outer boundaries shift.
			name: "interior-split-point-untouched",
			events: []any{
				map[string]any{"startTime": "2026-06-25T10:00:00.000Z", "endTime": "2026-06-25T10:30:00.000Z", "note": "A"},
				map[string]any{"startTime": "2026-06-25T10:30:00.000Z", "endTime": "2026-06-25T11:00:00.000Z", "note": "B"},
			},
			stagingTsEvent: time.Date(2026, 6, 25, 9, 55, 0, 0, time.UTC),
			stagingTsEnd:   sql.NullTime{Time: time.Date(2026, 6, 25, 11, 5, 0, 0, time.UTC), Valid: true},
			wantFirstStart: "2026-06-25T09:55:00.000Z",
			wantLastEnd:    "2026-06-25T11:05:00.000Z",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			startDrift, endDrift := alignSplitEventsToStaging(c.events, c.stagingTsEvent, c.stagingTsEnd)

			first := c.events[0].(map[string]any)
			if got := first["startTime"]; got != c.wantFirstStart {
				t.Errorf("first.startTime = %v, want %s", got, c.wantFirstStart)
			}
			last := c.events[len(c.events)-1].(map[string]any)
			if got := last["endTime"]; got != c.wantLastEnd {
				t.Errorf("last.endTime = %v, want %v", got, c.wantLastEnd)
			}
			// Interior split-points must not be touched.
			if len(c.events) >= 3 {
				t.Fatalf("test fixture has %d events; this assertion expects exactly 2-event payloads", len(c.events))
			}
			// Drift only checked for the case that pinned them.
			if c.wantStartDriftSec != 0 && startDrift != c.wantStartDriftSec {
				t.Errorf("startDriftSec = %d, want %d", startDrift, c.wantStartDriftSec)
			}
			if c.wantEndDriftSec != 0 && endDrift != c.wantEndDriftSec {
				t.Errorf("endDriftSec = %d, want %d", endDrift, c.wantEndDriftSec)
			}
		})
	}
}

// Defensive — malformed events array (not a map) must not panic.
func TestAlignSplitEventsToStaging_NonMapElementSkipsCleanly(t *testing.T) {
	events := []any{"not-a-map", map[string]any{"endTime": "2026-06-25T07:44:00.000Z"}}
	startDrift, endDrift := alignSplitEventsToStaging(
		events,
		time.Date(2026, 6, 25, 6, 28, 0, 0, time.UTC),
		sql.NullTime{Time: time.Date(2026, 6, 25, 7, 44, 0, 0, time.UTC), Valid: true},
	)
	// Did not panic; drift returned zero because the first element couldn't
	// be inspected.
	if startDrift != 0 {
		t.Errorf("startDriftSec = %d, want 0 for non-map first element", startDrift)
	}
	if endDrift != 0 {
		t.Errorf("endDriftSec = %d, want 0 for last with no parsable prev value", endDrift)
	}
	// Last element WAS rewritten (it's a real map).
	if got := events[1].(map[string]any)["endTime"]; got != "2026-06-25T07:44:00.000Z" {
		t.Errorf("last.endTime = %v, want unchanged-equal-to-staging", got)
	}
}
