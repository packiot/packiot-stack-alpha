// order_replaced_test.go — mirrors order_changed_test.go: same structural-
// skip path applies because the unmappable-PO failure mode is identical.
// DLQ ids 281 + 285 (source_log_ids 2503200, 2503474) both hit
// "production_order N unmapped" for the same reason — operator touched a
// PO before the mirror cursor began.
package replay

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/db"
	"github.com/packiot/packiot-stack-alpha/services/mirror-worker-go/internal/metrics"
	"github.com/prometheus/client_golang/prometheus/testutil"
)

const realOrderReplacedRaw = `{` +
	`"idEquipment":60,"idEnterprise":1,` +
	`"equipmentSetup":[{"id":62,"position":2},{"id":63,"position":3}],` +
	`"unitMultiplier":1,"idProductionOrder":1644916` +
	`}`

func TestOrderReplacedPayload_Unmarshal_RealProdShape(t *testing.T) {
	var p OrderReplacedPayload
	if err := decodeWithNumbers([]byte(realOrderReplacedRaw), &p); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if p.IDEquipment != 60 {
		t.Errorf("IDEquipment = %d, want 60", p.IDEquipment)
	}
	if p.IDProductionOrder != 1644916 {
		t.Errorf("IDProductionOrder = %d, want 1644916", p.IDProductionOrder)
	}
}

func TestOrderReplaced_SkipReplay_DispatcherRecordsSkipped(t *testing.T) {
	// Same shape as order-changed's skip test: a fake handler returns an
	// error wrapping ErrSkipReplay; the dispatcher must record
	// outcome=skipped (not outcome=failed) and not propagate the error.
	const evt = "order-replaced"
	beforeSkipped := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped"))
	beforeFailed := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return fmt.Errorf("production_order 1644916 unmapped (no mirror_id_map row and no id_order business-key match): %w", ErrSkipReplay)
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(realOrderReplacedRaw),
	})
	if err != nil {
		t.Fatalf("Dispatch err = %v, want nil for skip-replay", err)
	}
	if !errors.Is(fmt.Errorf("x: %w", ErrSkipReplay), ErrSkipReplay) {
		t.Fatal("errors.Is unwrap broken")
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "skipped")); got != beforeSkipped+1 {
		t.Errorf("order-replaced skipped = %f, want %f", got, beforeSkipped+1)
	}
	if got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "failed")); got != beforeFailed {
		t.Errorf("order-replaced failed = %f, want %f (skip must not bump failed)", got, beforeFailed)
	}
}
