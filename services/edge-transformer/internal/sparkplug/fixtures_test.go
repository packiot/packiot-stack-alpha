// Realistic Sparkplug B message fixtures for tests + benchmarks.
//
// Sparkplug B distinguishes between FOUR data-bearing message types:
//
//   NBIRTH   Node birth.   Full metric set with name + alias + initial value.
//                          Emitted at node connect and periodically.
//   DBIRTH   Device birth. Same shape, but for a sub-device.
//   NDATA    Node data.    Incremental updates. Alias-only references; relies
//                          on the receiver's NBIRTH-built alias table.
//   DDATA    Device data.  Incremental updates per device.
//
// NDATA/DDATA are 30-90% smaller than NBIRTH/DBIRTH on the wire because they
// drop the metric names. The receiver MUST maintain an alias→name map per
// publisher, rebuilt on every NBIRTH.
//
// These fixtures exercise both shapes so the benchmarks reflect realistic
// production traffic patterns.

package sparkplug

import (
	"fmt"
	"testing"
)

// cpackMetricNames returns N realistic CPACK-shaped metric topic names. They
// mirror the same packml_register entries the Phase 2.5b adapter consumes, so
// benchmark numbers reflect production-shape data.
func cpackMetricNames(n int) []string {
	machines := []string{
		"CPACK/SC/LINHAS/L5/BREYER",
		"CPACK/SC/LINHAS/L5/POLYTYPE",
		"CPACK/SC/LINHAS/L5/PTH",
		"CPACK/SC/LINHAS/L5/RMH",
		"CPACK/SC/LINHAS/L5/TEXA",
		"CPACK/SC/LINHAS/L3/BREYER",
		"CPACK/SC/LINHAS/L4/POLYTYPE",
		"CPACK/SC/CELULA1/DUBUTI2/DUBUTI2",
		"CPACK/SC/CELULA2/PTH80S/PTH80S",
		"CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1",
	}
	suffixes := []string{
		"Admin/ProdConsumedCount/61/Unit",
		"Admin/ProdProcessedCount/62/Unit",
		"Admin/ProdDefectiveCount/63/Unit",
		"Status/StateCurrent",
		"Status/SpeedRPM",
		"Status/Temperature",
	}
	out := make([]string, n)
	for i := 0; i < n; i++ {
		out[i] = fmt.Sprintf("%s/%s",
			machines[i%len(machines)],
			suffixes[i%len(suffixes)])
	}
	return out
}

// newNBIRTH builds a node-birth payload: N metrics with both name and alias.
// The alias is the receiver's shortcut to skip name parsing in subsequent
// NDATA/DDATA messages. NBIRTH is the larger of the two parse paths because
// the names dominate the wire size.
func newNBIRTH(nMetrics int, baseTimestamp uint64) *Payload {
	names := cpackMetricNames(nMetrics)
	metrics := make([]*Metric, nMetrics)
	for i := 0; i < nMetrics; i++ {
		metrics[i] = &Metric{
			Name:      ptr(names[i]),
			Alias:     ptr(uint64(i)),
			Timestamp: ptr(baseTimestamp + uint64(i)),
			Datatype:  ptr(uint32(DataType_Int64.Number())),
			Value:     &Metric_LongValue{LongValue: uint64(1000 + i)},
		}
	}
	return &Payload{
		Timestamp: ptr(baseTimestamp),
		Seq:       ptr(uint64(0)), // NBIRTH always seq=0
		Metrics:   metrics,
	}
}

// newNDATA builds a node-data payload: N metrics with ONLY alias (no names).
// This is the wire shape that 95%+ of real factory traffic uses. The receiver
// resolves alias → name via the per-publisher table built from NBIRTH. The
// alias-only path is ~3-5× smaller on the wire than NBIRTH for the same
// metric count.
func newNDATA(nMetrics int, baseTimestamp uint64, seq uint64) *Payload {
	metrics := make([]*Metric, nMetrics)
	for i := 0; i < nMetrics; i++ {
		metrics[i] = &Metric{
			Alias:     ptr(uint64(i)),
			Timestamp: ptr(baseTimestamp + uint64(i)),
			Datatype:  ptr(uint32(DataType_Int64.Number())),
			Value:     &Metric_LongValue{LongValue: uint64(2000 + i)},
		}
	}
	return &Payload{
		Timestamp: ptr(baseTimestamp),
		Seq:       ptr(seq),
		Metrics:   metrics,
	}
}

// TestFixtureShapes asserts each fixture passes the decoder cleanly and the
// alias-only NDATA shape is meaningfully smaller than the NBIRTH shape — the
// expected wire-format characteristic that motivates Sparkplug B's design.
func TestFixtureShapes(t *testing.T) {
	const baseTs = 1782849957000

	nbirth := newNBIRTH(100, baseTs)
	ndata := newNDATA(100, baseTs, 5)

	nbirthBody, err := Encode(nbirth)
	if err != nil {
		t.Fatalf("encode nbirth: %v", err)
	}
	ndataBody, err := Encode(ndata)
	if err != nil {
		t.Fatalf("encode ndata: %v", err)
	}

	t.Logf("100-metric NBIRTH wire size: %d bytes", len(nbirthBody))
	t.Logf("100-metric NDATA  wire size: %d bytes", len(ndataBody))
	t.Logf("ratio NBIRTH/NDATA: %.2fx", float64(len(nbirthBody))/float64(len(ndataBody)))

	// Sanity: NDATA should be at least 2× smaller (no metric names)
	if len(ndataBody)*2 > len(nbirthBody) {
		t.Errorf("expected NDATA ≥2× smaller than NBIRTH; got %d vs %d",
			len(ndataBody), len(nbirthBody))
	}

	// Round-trip both
	for _, tc := range []struct {
		name string
		body []byte
		want *Payload
	}{
		{"nbirth", nbirthBody, nbirth},
		{"ndata", ndataBody, ndata},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Decode(tc.body)
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if len(got.GetMetrics()) != 100 {
				t.Errorf("want 100 metrics, got %d", len(got.GetMetrics()))
			}
			if got.GetSeq() != tc.want.GetSeq() {
				t.Errorf("seq: got %d, want %d", got.GetSeq(), tc.want.GetSeq())
			}
		})
	}
}
