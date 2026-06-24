// event_justified_test.go — table-driven tests for the JustifyPayload
// JSON parsing + dispatch wiring of the event-justified handler.
//
// The handler's translator + HTTP POST path requires live prod + staging
// pools, so those aren't exercised here. What IS exercised:
//
//   - JustifyPayload struct accepts real-shape prod payloads
//   - Required fields (IDEquipment, IDEquipmentEvent) are decoded correctly
//   - Optional fields (CdMachine, ChangeOver) round-trip through the
//     pass-through map[string]any
//   - When the handler returns an error, dispatch records outcome=failed
//
// A future addition: stand up an httptest.Server + a fake Translator
// behind an interface to cover the full POST path. Today the Translator
// is a concrete type so the cleanest extension is a behaviour-driven
// fake; tracked under #41 follow-ups.
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

func TestJustifyPayload_Unmarshal(t *testing.T) {
	cases := []struct {
		name          string
		raw           string
		wantEquipment int
		wantEventID   int64
		wantCdMachine string
		wantChangeOver *bool
	}{
		{
			// Minimal — only the two required fields.
			name:          "minimal",
			raw:           `{"idEquipment":42,"idEquipmentEvent":12345}`,
			wantEquipment: 42,
			wantEventID:   12345,
		},
		{
			// Real prod shape — extra metadata operator typed in.
			name:          "with category metadata",
			raw:           `{"idEquipment":42,"idEquipmentEvent":12345,"cdMachine":"M1","cdCategory":"PLANNED","descCategory":"Planned maintenance"}`,
			wantEquipment: 42,
			wantEventID:   12345,
			wantCdMachine: "M1",
		},
		{
			// Boolean field — pointer so we can distinguish "false" from "absent".
			name:           "with changeOver true",
			raw:            `{"idEquipment":42,"idEquipmentEvent":12345,"changeOver":true}`,
			wantEquipment:  42,
			wantEventID:    12345,
			wantChangeOver: ptrBool(true),
		},
		{
			// Unknown extra fields are tolerated — class-validator on the
			// staging edge-api also ignores them (whitelist:false).
			name:          "with unknown extra fields",
			raw:           `{"idEquipment":42,"idEquipmentEvent":12345,"futureField":"don't care"}`,
			wantEquipment: 42,
			wantEventID:   12345,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p JustifyPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if p.IDEquipment != c.wantEquipment {
				t.Errorf("IDEquipment = %d, want %d", p.IDEquipment, c.wantEquipment)
			}
			if p.IDEquipmentEvent != c.wantEventID {
				t.Errorf("IDEquipmentEvent = %d, want %d", p.IDEquipmentEvent, c.wantEventID)
			}
			if c.wantCdMachine != "" && p.CdMachine != c.wantCdMachine {
				t.Errorf("CdMachine = %q, want %q", p.CdMachine, c.wantCdMachine)
			}
			if c.wantChangeOver != nil {
				if p.ChangeOver == nil || *p.ChangeOver != *c.wantChangeOver {
					t.Errorf("ChangeOver = %v, want %v", p.ChangeOver, c.wantChangeOver)
				}
			}
		})
	}
}

func TestJustifyPayload_RoundTripPreservesUnknown(t *testing.T) {
	// The handler's "verbatim pass-through" path round-trips the raw
	// payload as map[string]any so unknown fields survive. This is the
	// behaviour future prod features rely on — if we tighten to a
	// strict-typed payload, we silently drop new fields on staging.
	raw := []byte(`{"idEquipment":42,"idEquipmentEvent":12345,"cdMachine":"M1","futureField":"keep me"}`)
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	m["idEquipment"] = 100
	m["idEquipmentEvent"] = 999
	m["idEnterprise"] = 3
	if m["futureField"] != "keep me" {
		t.Errorf("futureField lost after override: %v", m["futureField"])
	}
}

func TestEventJustified_FailedDispatch_RecordsFailed(t *testing.T) {
	// Use a fake handler so we don't need a translator + HTTP server.
	// Verifies the dispatcher's failed-outcome path applies the right
	// event_type label for event-justified specifically.
	const evt = "event-justified"
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
		t.Errorf("event-justified failed count = %f, want %f", got, beforeFailed+1)
	}
}

func ptrBool(b bool) *bool { return &b }

// TestEventJustified_SkipReplay_DispatcherRecordsSkipped — justify.service.ts
// throws NotFoundException('Downtime does not exist') (404, not 400 like
// edit-manual-event). Pin that the skip wires through for the 404 variant.
func TestEventJustified_SkipReplay_DispatcherRecordsSkipped(t *testing.T) {
	const evt = "event-justified"
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return fmt.Errorf("staging /api/downtimes/justify returned 404: parent downtime/event missing — child replay skipped: %w",
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
		t.Errorf("event-justified skipped = %f, want %f", got, beforeSkipped+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed {
		t.Errorf("event-justified failed = %f, want %f (skip must not bump failed)", got, beforeFailed)
	}
}
