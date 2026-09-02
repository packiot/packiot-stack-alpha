package writers

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/packiot/packiot-stack-alpha/services/stream-engine/internal/sparkplug"
)

// The "unroutable topic" silent-drop guard (packml_unresolved_topic_total):
// when a CanWrite metric's packml_topic has no active packml_register row the
// resolver returns (nil,nil) and Build skips it (ack-not-nack — retry can't
// conjure the row). Until this counter, that drop was visible only in a 1/32
// sampled log, so a missing/inactive register row produced ZERO
// equipment_values with green pipelines. These tests pin the counter to that
// EXACT branch, labelled by tenant (bounded), and prove the skip semantics are
// otherwise unchanged.

const ghostTopic = "GHOST/SC/LINHAS/L9/Admin/ProdConsumedCount/61/Unit"
const ghostRegister = "GHOST/SC/LINHAS/L9" // TopicForRegister (parts[4]=="Admin" → 4-seg line row)

// unregMetric parses a real Sparkplug envelope for an unregistered topic so
// Classify()/TopicForRegister() run exactly as on the wire.
func unregMetric(t *testing.T, tsMs int64) *sparkplug.Metric {
	t.Helper()
	body := []byte(fmt.Sprintf(
		`{"timestamp":%d,"metrics":[{"name":%q,"timestamp":%d,"value":5,"counter":100,"curspeed":120}]}`,
		tsMs, ghostTopic, tsMs))
	p, err := sparkplug.Parse(body)
	if err != nil {
		t.Fatalf("parse envelope: %v", err)
	}
	return &p.Metrics[0]
}

func newUnresolvedVec() *prometheus.CounterVec {
	return prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "packml_unresolved_topic_total",
		Help: "test",
	}, []string{"tenant"})
}

// TestBuild_UnresolvedTopic_IncrementsCounter: an unregistered topic must
// (a) return (nil,nil,nil) — a skip, not an error — and (b) tick
// packml_unresolved_topic_total{tenant="ghost"} exactly once. tenant is the
// lowercased first topic segment.
func TestBuild_UnresolvedTopic_IncrementsCounter(t *testing.T) {
	// Negative cache entry (info=nil) → Resolve returns (nil,nil) from cache
	// without ever touching the (nil) pool.
	r := sparkplug.NewResolver(nil, time.Hour, time.Hour)
	r.SeedForTest(ghostRegister, nil)

	vec := newUnresolvedVec()
	w := NewEquipmentValues(r, slog.New(slog.NewTextHandler(io.Discard, nil)))
	w.SetUnresolvedMetric(vec)

	m := unregMetric(t, 1_700_000_000_000)
	q, clampEv, err := w.Build(context.Background(), m, "gw", "public")
	if err != nil {
		t.Fatalf("unregistered topic must skip, not error; got err=%v", err)
	}
	if q != nil {
		t.Fatalf("unregistered topic must produce no Query; got %+v", q)
	}
	if clampEv != nil {
		t.Fatalf("unregistered topic must produce no clamp event; got %+v", clampEv)
	}
	if got := testutil.ToFloat64(vec.WithLabelValues("ghost")); got != 1 {
		t.Errorf("packml_unresolved_topic_total{tenant=\"ghost\"} = %v, want 1", got)
	}
	// Cardinality discipline: the full topic string must NOT be a label —
	// only the bounded tenant series should exist.
	if n := testutil.CollectAndCount(vec); n != 1 {
		t.Errorf("expected exactly 1 tenant series, got %d (full-topic label would be unbounded)", n)
	}

	// A registered topic arriving right after must NOT tick the counter —
	// proves the increment is scoped to the info==nil branch.
	r.SeedForTest(ghostRegister, &sparkplug.EquipmentInfo{
		IDEnterprise: 9, IDSite: 90, IDArea: 900, IDEquipment: 999,
	})
	if _, _, err := w.Build(context.Background(), unregMetric(t, 1_700_000_001_000), "gw", "public"); err != nil {
		t.Fatalf("registered topic Build: %v", err)
	}
	if got := testutil.ToFloat64(vec.WithLabelValues("ghost")); got != 1 {
		t.Errorf("counter moved on a RESOLVED topic: got %v, want still 1", got)
	}
}

// TestBuild_UnresolvedTopic_NilMetric_NoPanic: the counter is optional. A
// writer built without SetUnresolvedMetric must skip the unresolved topic
// exactly as before — byte-for-byte flag-off parity, no panic.
func TestBuild_UnresolvedTopic_NilMetric_NoPanic(t *testing.T) {
	r := sparkplug.NewResolver(nil, time.Hour, time.Hour)
	r.SeedForTest(ghostRegister, nil)
	w := NewEquipmentValues(r, slog.New(slog.NewTextHandler(io.Discard, nil)))
	// no SetUnresolvedMetric → w.unresolved stays nil

	q, _, err := w.Build(context.Background(), unregMetric(t, 1_700_000_000_000), "gw", "public")
	if err != nil || q != nil {
		t.Fatalf("nil-metric skip must be (nil,nil,nil); got q=%+v err=%v", q, err)
	}
}

// TestTenantFromTopic pins the label-derivation to the same rule as
// handlers.tenantOf and packml_register discovery.
func TestTenantFromTopic(t *testing.T) {
	cases := map[string]string{
		"CPACK/SC/LINHAS/L5/Admin/ProdConsumedCount": "cpack",
		"Incoplast/A/B":                              "incoplast",
		"loneword":                                   "loneword",
		"":                                           "unknown",
	}
	for in, want := range cases {
		if got := tenantFromTopic(in); got != want {
			t.Errorf("tenantFromTopic(%q) = %q, want %q", in, got, want)
		}
	}
}
