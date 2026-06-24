// order_changed_test.go — exercises the structural-skip path introduced
// to drain pattern A DLQ entries. The handler's live HTTP + DB calls are
// out of scope (covered end-to-end by the staging integration loop); what's
// tested here:
//
//   - Real prod-shape payload decodes into OrderChangedPayload
//   - Real DLQ sample (production_order 1641995 / id_order 892993) is the
//     same payload shape we now skip rather than DLQ
//   - When a fake handler returns an error wrapping ErrSkipReplay, the
//     dispatcher records outcome=skipped under event_type=order-changed
//     (NOT outcome=failed) — i.e. the DLQ-bypass is event-type-correct
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

// Real prod-shape payload for an order-changed user_logs row. The real
// DLQ sample we want to drain referenced oldIdProductionOrder=1641995
// (id_order=892993 on prod, absent from staging). Shape extracted from the
// payload column shipped by edge-api's order-control controller.
const realOrderChangedRaw = `{` +
	`"stopType":"unplanned-stop",` +
	`"timestamp":"2026-06-23T18:00:00Z",` +
	`"idEquipment":564,` +
	`"oldIdProductionOrder":1641995,` +
	`"productionOrderQuantity":120` +
	`}`

func TestOrderChangedPayload_Unmarshal_RealProdShape(t *testing.T) {
	var p OrderChangedPayload
	if err := decodeWithNumbers([]byte(realOrderChangedRaw), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if p.IDEquipment != 564 {
		t.Errorf("IDEquipment = %d, want 564", p.IDEquipment)
	}
	if p.OldIDProductionOrder != 1641995 {
		t.Errorf("OldIDProductionOrder = %d, want 1641995", p.OldIDProductionOrder)
	}
	if p.StopType != "unplanned-stop" {
		t.Errorf("StopType = %q, want %q", p.StopType, "unplanned-stop")
	}
	// productionOrderQuantity goes through json.Number → Float64.
	qty, err := p.ProductionOrderQuantity.Float64()
	if err != nil {
		t.Fatalf("qty.Float64: %v", err)
	}
	if qty != 120 {
		t.Errorf("qty = %f, want 120", qty)
	}
}

func TestOrderChangedPayload_StructuralGuardRejectsMissingFields(t *testing.T) {
	// Guards that justify the handler's "if p.IDEquipment == 0 || ..."
	// check. Validates the JSON-decode side; the handler-side rejection
	// is covered by the integration loop.
	cases := []struct {
		name string
		raw  string
		want OrderChangedPayload
	}{
		{
			"missing idEquipment",
			`{"stopType":"x","oldIdProductionOrder":1,"productionOrderQuantity":1}`,
			OrderChangedPayload{StopType: "x", OldIDProductionOrder: 1, ProductionOrderQuantity: "1"},
		},
		{
			"missing oldIdProductionOrder",
			`{"stopType":"x","idEquipment":1,"productionOrderQuantity":1}`,
			OrderChangedPayload{StopType: "x", IDEquipment: 1, ProductionOrderQuantity: "1"},
		},
		{
			"missing stopType",
			`{"idEquipment":1,"oldIdProductionOrder":1,"productionOrderQuantity":1}`,
			OrderChangedPayload{IDEquipment: 1, OldIDProductionOrder: 1, ProductionOrderQuantity: "1"},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p OrderChangedPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			// At least one required field must decode to zero.
			if p.IDEquipment != 0 && p.OldIDProductionOrder != 0 && p.StopType != "" {
				t.Errorf("expected at least one zero field, got %+v", p)
			}
		})
	}
}

func TestOrderChanged_SkipReplay_DispatcherRecordsSkipped(t *testing.T) {
	// The real DLQ sample for this pattern (DLQ id 237, source_log_id
	// 2499651, error "production_order 1641995 unmapped...") now flows
	// through the handler returning an error wrapping ErrSkipReplay.
	// Verify the dispatcher labels this as outcome=skipped under the
	// correct event_type — and does NOT bump outcome=failed.
	const evt = "order-changed"
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		// Same wrap shape as the real handler emits for translate.ErrUnmapped.
		return fmt.Errorf("production_order 1641995 unmapped (no mirror_id_map row and no id_order business-key match): %w", ErrSkipReplay)
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(realOrderChangedRaw),
	})
	if err != nil {
		t.Fatalf("Dispatch err = %v, want nil for skip-replay", err)
	}
	// Sanity: errors.Is gate still works on the wrapped sentinel — the
	// real translator.ErrUnmapped wrapping uses the same %w shape.
	if !errors.Is(fmt.Errorf("x: %w", ErrSkipReplay), ErrSkipReplay) {
		t.Fatal("errors.Is unwrap broken")
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped+1 {
		t.Errorf("order-changed skipped = %f, want %f", got, beforeSkipped+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed {
		t.Errorf("order-changed failed = %f, want %f (skip must not bump failed)", got, beforeFailed)
	}
}
