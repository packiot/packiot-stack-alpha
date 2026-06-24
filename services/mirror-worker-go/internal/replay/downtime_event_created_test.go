// downtime_event_created_test.go — table-driven tests mirroring
// event_justified_test.go for the new handler.
//
// As with the other replay tests, the live translator + HTTP path
// requires DB + HTTP fixtures and is out of scope. What's exercised:
//
//   - DowntimeEventCreatedPayload parses real prod-shape payloads
//   - Missing required fields (idEquipment / status / timestamp) decode to
//     zero and are rejected by the handler's structural guard
//   - When the handler errors, dispatch records outcome=failed with the
//     correct event_type label
package replay

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

// Real prod-shape payload, taken via SSM from prod's user_logs row
// id_user_logs=2501637 (2026-06-24).
const realDowntimeEventCreatedRaw = `{"events":[{"topic":"C-PACK/SC/LINHAS/L10/DXL/Status/StateCurrent","status":10,"timestamp":1782333900000,"idEquipment":564}]}`

func TestDowntimeEventCreatedPayload_Unmarshal(t *testing.T) {
	cases := []struct {
		name           string
		raw            string
		wantEventCount int
		wantEquipment  int
		wantStatus     int
		wantTimestamp  int64
		wantTopic      string
	}{
		{
			name:           "real prod single-event payload",
			raw:            realDowntimeEventCreatedRaw,
			wantEventCount: 1,
			wantEquipment:  564,
			wantStatus:     10,
			wantTimestamp:  1782333900000,
			wantTopic:      "C-PACK/SC/LINHAS/L10/DXL/Status/StateCurrent",
		},
		{
			// Status 6 = running (Status.running). Same shape, different
			// status — pinning here so an op who reads only status:10
			// doesn't conclude this handler is downtime-only.
			name:           "status=running",
			raw:            `{"events":[{"topic":"X/Y","status":6,"timestamp":1700000000000,"idEquipment":100}]}`,
			wantEventCount: 1,
			wantEquipment:  100,
			wantStatus:     6,
			wantTimestamp:  1700000000000,
			wantTopic:      "X/Y",
		},
		{
			// Multi-event batch — the controller accepts a slice and prod
			// has historically batched bursts. Verify count parsing.
			name: "multi-event batch",
			raw: `{"events":[` +
				`{"topic":"A","status":10,"timestamp":1700000000000,"idEquipment":1},` +
				`{"topic":"B","status":6,"timestamp":1700000001000,"idEquipment":2}` +
				`]}`,
			wantEventCount: 2,
			wantEquipment:  1, // first event
			wantStatus:     10,
			wantTimestamp:  1700000000000,
			wantTopic:      "A",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p DowntimeEventCreatedPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if len(p.Events) != c.wantEventCount {
				t.Fatalf("event count = %d, want %d", len(p.Events), c.wantEventCount)
			}
			e := p.Events[0]
			if e.IDEquipment != c.wantEquipment {
				t.Errorf("IDEquipment = %d, want %d", e.IDEquipment, c.wantEquipment)
			}
			if e.Status != c.wantStatus {
				t.Errorf("Status = %d, want %d", e.Status, c.wantStatus)
			}
			if e.Timestamp != c.wantTimestamp {
				t.Errorf("Timestamp = %d, want %d", e.Timestamp, c.wantTimestamp)
			}
			if e.Topic != c.wantTopic {
				t.Errorf("Topic = %q, want %q", e.Topic, c.wantTopic)
			}
		})
	}
}

func TestDowntimeEventCreatedPayload_MissingFieldsZero(t *testing.T) {
	// Defensive: payloads missing required fields decode to zero ints.
	// The handler's structural guard then rejects them — verify the
	// decode behaviour so the guard's "if e.IDEquipment == 0 || ..."
	// check stays meaningful.
	cases := []struct {
		name string
		raw  string
	}{
		{"no events array", `{}`},
		{"empty events", `{"events":[]}`},
		{"missing idEquipment", `{"events":[{"topic":"X","status":10,"timestamp":1700000000000}]}`},
		{"missing status", `{"events":[{"topic":"X","timestamp":1700000000000,"idEquipment":100}]}`},
		{"missing timestamp", `{"events":[{"topic":"X","status":10,"idEquipment":100}]}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p DowntimeEventCreatedPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			// The handler's guard either rejects empty/missing events
			// or the per-event zero check. Confirm decode produced one of
			// the two reject-able shapes.
			if len(p.Events) == 0 {
				return // covered by len(p.Events)==0 path
			}
			e := p.Events[0]
			if e.IDEquipment != 0 && e.Status != 0 && e.Timestamp != 0 {
				t.Errorf("expected at least one zero field, got %+v", e)
			}
		})
	}
}

func TestDowntimeEventCreated_FailedDispatch_RecordsFailed(t *testing.T) {
	// Use a fake handler so we don't need a translator + HTTP server —
	// same shape as the existing event-justified test. Verifies the
	// dispatcher's failed-outcome path applies the right event_type
	// label for downtime-event-created specifically.
	const evt = "downtime-event-created"
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return errors.New("translate equipment: unmapped on staging")
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(realDowntimeEventCreatedRaw),
	})
	if err == nil {
		t.Fatal("Dispatch err = nil, want non-nil from fake handler")
	}

	got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))
	if got != beforeFailed+1 {
		t.Errorf("downtime-event-created failed count = %f, want %f", got, beforeFailed+1)
	}
}
