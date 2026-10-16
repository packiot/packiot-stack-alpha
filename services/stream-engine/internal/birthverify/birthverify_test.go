package birthverify

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

type fakeRes map[string]*sparkplug.EquipmentInfo

func (f fakeRes) Resolve(_ context.Context, topic string) (*sparkplug.EquipmentInfo, error) {
	if topic == "CPACK/SC/LINHAS/ERR" {
		return nil, errors.New("db down")
	}
	return f[topic], nil
}

// The decoder's real wire shape (edge-transformer birthbind_wiring.go) parsed by
// the real parser: covers every result once.
const body = `{"timestamp":1,"gateway":"g","source_type":"refactored","id_enterprise":3,"metrics":[
 {"name":"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/1/Unit","timestamp":1,"value":1,"id_equipment":47,"role":"counter.gross"},
 {"name":"CPACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/2/Unit","timestamp":1,"value":1,"id_equipment":99,"role":"counter.net"},
 {"name":"CPACK/SC/LINHAS/L6/Admin/ProdDefectiveCount/3/Unit","timestamp":1,"value":1,"id_equipment":60,"role":"counter.gross"},
 {"name":"CPACK/SC/LINHAS/L7/Admin/ProdConsumedCount/4/Unit","timestamp":1,"value":1},
 {"name":"CPACK/SC/LINHAS/L9/Admin/ProdConsumedCount/5/Unit","timestamp":1,"value":1,"id_equipment":90,"role":"counter.gross"},
 {"name":"CPACK/SC/LINHAS/ERR/Admin/ProdConsumedCount/6/Unit","timestamp":1,"value":1,"id_equipment":91,"role":"counter.gross"},
 {"name":"CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/7/Unit","timestamp":1,"value":1,"id_equipment":80,"role":"counter.gross"},
 {"name":"CPACK/SC/LINHAS/L5/Status/CurMachSpeed","timestamp":1,"value":3,"id_equipment":47,"role":"speed.current"},
 {"name":"CPACK/SC/LINHAS/L5/Status/Parameter","timestamp":1,"value":3,"id":30701}
]}`

func TestCheck_EveryOutcome(t *testing.T) {
	res := fakeRes{
		"CPACK/SC/LINHAS/L5":        {IDEquipment: 47, IDEnterprise: 3},
		"CPACK/SC/LINHAS/L5/BREYER": {IDEquipment: 53, IDEnterprise: 3}, // stamped 99
		"CPACK/SC/LINHAS/L6":        {IDEquipment: 60, IDEnterprise: 3}, // role says gross, leaf says scrap
		"CPACK/SC/LINHAS/L8":        {IDEquipment: 80, IDEnterprise: 5}, // other tenant
		// L9 absent ⇒ legacy_unresolved
	}
	v := New(res, prometheus.NewRegistry(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	p, err := sparkplug.Parse([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	v.Check(context.Background(), p, "cpack")

	want := map[string]float64{
		"match": 2, "mismatch_equipment": 1, "mismatch_role": 1, "unbound": 1,
		"legacy_unresolved": 1, "legacy_error": 1, "mismatch_enterprise": 1,
	}
	for result, n := range want {
		if got := testutil.ToFloat64(v.results.WithLabelValues("cpack", result)); got != n {
			t.Errorf("%s = %v, want %v", result, got, n)
		}
	}
	// the speed metric is verified (a declared role, ADR-0061 D2) — the parameter is not
	if got := testutil.CollectAndCount(v.results); got != len(want) {
		t.Errorf("series = %d, want %d", got, len(want))
	}
}

func TestCheck_NilIsOff(t *testing.T) {
	var v *Verifier
	p, _ := sparkplug.Parse([]byte(body))
	v.Check(context.Background(), p, "cpack") // must not panic
}

// An envelope from a decoder with BIRTH_BOUND_ROUTING off: every counter is unbound,
// nothing is resolved (no DB load for the legacy path).
func TestCheck_UnstampedNeverResolves(t *testing.T) {
	calls := 0
	v := New(countingRes{&calls}, prometheus.NewRegistry(), slog.New(slog.NewTextHandler(io.Discard, nil)))
	p, _ := sparkplug.Parse([]byte(`{"timestamp":1,"metrics":[{"name":"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount/1/Unit","value":1}]}`))
	v.Check(context.Background(), p, "cpack")
	if calls != 0 || testutil.ToFloat64(v.results.WithLabelValues("cpack", "unbound")) != 1 {
		t.Errorf("calls=%d unbound=%v, want 0 calls / 1 unbound", calls, testutil.ToFloat64(v.results.WithLabelValues("cpack", "unbound")))
	}
}

type countingRes struct{ n *int }

func (c countingRes) Resolve(context.Context, string) (*sparkplug.EquipmentInfo, error) {
	*c.n++
	return nil, nil
}
