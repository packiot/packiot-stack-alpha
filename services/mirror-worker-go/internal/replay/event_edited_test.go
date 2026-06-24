// event_edited_test.go — mirrors event_justified_test.go for the
// event-edited handler.
//
// Coverage:
//   - EditPayload struct parses real prod payloads
//   - When the handler returns a failure, dispatch records outcome=failed
//   - When the handler returns an error wrapping ErrSkipReplay
//     (chicken-and-egg parent-missing case, PR #59), dispatch records
//     outcome=skipped and does NOT bump outcome=failed
//
// The live translator + HTTP path stays out of scope (covered end-to-end
// by httputil_test.go via httptest.Server).
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

func TestEditPayload_Unmarshal(t *testing.T) {
	cases := []struct {
		name          string
		raw           string
		wantEquipment int
		wantEventID   int64
	}{
		{
			name:          "minimal",
			raw:           `{"idEquipment":42,"idEquipmentEvent":12345}`,
			wantEquipment: 42,
			wantEventID:   12345,
		},
		{
			// Real prod-shape payload — extra metadata operator typed in.
			// The pass-through map[string]any preserves these on POST.
			name:          "with metadata",
			raw:           `{"idEquipment":42,"idEquipmentEvent":12345,"cdMachine":"M1","start":"2026-06-24T10:00:00Z","end":"2026-06-24T10:05:00Z"}`,
			wantEquipment: 42,
			wantEventID:   12345,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p EditPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if p.IDEquipment != c.wantEquipment {
				t.Errorf("IDEquipment = %d, want %d", p.IDEquipment, c.wantEquipment)
			}
			if p.IDEquipmentEvent != c.wantEventID {
				t.Errorf("IDEquipmentEvent = %d, want %d", p.IDEquipmentEvent, c.wantEventID)
			}
		})
	}
}

func TestEventEdited_FailedDispatch_RecordsFailed(t *testing.T) {
	const evt = "event-edited"
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return errors.New("translator: equipment_event unmapped")
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(`{"idEquipment":42,"idEquipmentEvent":12345}`),
	})
	if err == nil {
		t.Fatal("Dispatch err = nil, want non-nil from fake handler")
	}

	got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))
	if got != beforeFailed+1 {
		t.Errorf("event-edited failed count = %f, want %f", got, beforeFailed+1)
	}
}

// TestEventEdited_SkipReplay_DispatcherRecordsSkipped — the 33 chicken-
// and-egg DLQ entries today (DLQ ids 234, 235, 238…) all carried
// "staging /api/downtimes/edit-manual-event returned 400: ...Downtime
// does not exist...". With PR #59 those rows flow through the handler
// returning an error wrapping ErrSkipReplay; dispatcher labels them
// outcome=skipped and the caller (processRow) takes the no-DLQ branch.
func TestEventEdited_SkipReplay_DispatcherRecordsSkipped(t *testing.T) {
	const evt = "event-edited"
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		// Same wrap shape PostStaging emits when classifyStagingError
		// promotes a "Downtime does not exist" 400 to a skip.
		return fmt.Errorf("staging /api/downtimes/edit-manual-event returned 400: parent downtime/event missing — child replay skipped: %w",
			ErrSkipReplay)
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(`{"idEquipment":42,"idEquipmentEvent":12345}`),
	})
	if err != nil {
		t.Fatalf("Dispatch err = %v, want nil for skip-replay", err)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped+1 {
		t.Errorf("event-edited skipped = %f, want %f", got, beforeSkipped+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed {
		t.Errorf("event-edited failed = %f, want %f (skip must not bump failed)", got, beforeFailed)
	}
}
