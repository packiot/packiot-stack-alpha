// order_status_changed_test.go — tests for OrderStatusChangedPayload
// parsing + the dispatch path's outcome accounting.
//
// As with event_justified_test.go, the translator + HTTP path is out of
// scope — those need DB + HTTP fixtures.
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

func TestOrderStatusChangedPayload_Unmarshal(t *testing.T) {
	cases := []struct {
		name        string
		raw         string
		wantEq      int
		wantPO      int64
	}{
		{
			name:   "small ids",
			raw:    `{"idEquipment":1,"idProductionOrder":2}`,
			wantEq: 1,
			wantPO: 2,
		},
		{
			// Big int — id_production_order can outgrow int32. Real prod
			// values cross 2^31 on the live cpack-prod dump.
			name:   "large idProductionOrder",
			raw:    `{"idEquipment":42,"idProductionOrder":9999999999}`,
			wantEq: 42,
			wantPO: 9999999999,
		},
		{
			// Extra unrelated fields tolerated.
			name:   "with extras",
			raw:    `{"idEquipment":42,"idProductionOrder":100,"extra":"ignore"}`,
			wantEq: 42,
			wantPO: 100,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p OrderStatusChangedPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if p.IDEquipment != c.wantEq {
				t.Errorf("IDEquipment = %d, want %d", p.IDEquipment, c.wantEq)
			}
			if p.IDProductionOrder != c.wantPO {
				t.Errorf("IDProductionOrder = %d, want %d", p.IDProductionOrder, c.wantPO)
			}
		})
	}
}

func TestOrderStatusChangedPayload_MissingFieldsZero(t *testing.T) {
	// Defensive: payloads missing required fields decode to zero ints.
	// The handler MUST then return a "missing fields" error rather than
	// silently dispatch to staging — verifies the structural guard.
	cases := []struct {
		name string
		raw  string
	}{
		{"no equipment", `{"idProductionOrder":2}`},
		{"no PO", `{"idEquipment":1}`},
		{"empty object", `{}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var p OrderStatusChangedPayload
			if err := json.Unmarshal([]byte(c.raw), &p); err != nil {
				t.Fatalf("unmarshal: %v", err)
			}
			if p.IDEquipment != 0 && p.IDProductionOrder != 0 {
				t.Errorf("expected at least one zero field, got %+v", p)
			}
		})
	}
}

func TestOrderStatusChanged_OKDispatch_RecordsOK(t *testing.T) {
	const evt = "order-status-changed"
	beforeOK := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "ok"))

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return nil
	})

	err := d.Dispatch(context.Background(), nil, db.ProdUserLog{
		Category: evt,
		Payload:  []byte(`{"idEquipment":1,"idProductionOrder":2}`),
	})
	if err != nil {
		t.Fatalf("Dispatch err = %v", err)
	}

	got := testutil.ToFloat64(metrics.UserLogsReplayedTotal.WithLabelValues(evt, "ok"))
	if got != beforeOK+1 {
		t.Errorf("order-status-changed ok count = %f, want %f", got, beforeOK+1)
	}
}

func TestOrderStatusChanged_HandlerErrorPropagates(t *testing.T) {
	// The handler's behaviour is "return err from translate → DLQ".
	// Pinning the propagation here so a future refactor of Dispatch
	// (e.g. retry-wrapping) doesn't silently swallow the error.
	const evt = "order-status-changed"
	wantErr := errors.New("translate equipment failed")

	d := NewDispatcher()
	d.Register(evt, func(_ context.Context, _ pgx.Tx, _ db.ProdUserLog) error {
		return wantErr
	})

	gotErr := d.Dispatch(context.Background(), nil, db.ProdUserLog{Category: evt})
	if !errors.Is(gotErr, wantErr) {
		t.Errorf("err = %v, want %v", gotErr, wantErr)
	}
}
