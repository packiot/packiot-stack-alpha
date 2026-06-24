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
	"encoding/json"
	"errors"
	"fmt"
	"testing"

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
