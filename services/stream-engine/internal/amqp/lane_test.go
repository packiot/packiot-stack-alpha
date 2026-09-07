package amqp

import "testing"

// TestSourceTypeOf covers the cheap hot-path extraction of the top-level
// source_type from a raw envelope — the value laneFor keys on.
func TestSourceTypeOf(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string
	}{
		{"refactored", `{"timestamp":1,"source_type":"refactored","metrics":[]}`, "refactored"},
		{"go", `{"source_type":"go","gateway":"x"}`, "go"},
		{"empty_f1", `{"timestamp":1,"source_type":"","metrics":[]}`, ""},
		{"absent", `{"timestamp":1,"metrics":[]}`, ""},
		{"garbage", `not json at all`, ""},
		{"source_type_last", `{"metrics":[],"source_type":"go"}`, "go"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := sourceTypeOf([]byte(c.body)); got != c.want {
				t.Errorf("sourceTypeOf(%s) = %q, want %q", c.body, got, c.want)
			}
		})
	}
}

// TestLaneForDeterministic is the load-bearing correctness invariant: a given
// source_type ALWAYS routes to the same lane, so its messages stay strictly
// ordered (required for po-control lifecycle read-modify-write).
func TestLaneForDeterministic(t *testing.T) {
	bodyA1 := []byte(`{"source_type":"refactored","metrics":[{"name":"a"}]}`)
	bodyA2 := []byte(`{"source_type":"refactored","metrics":[{"name":"z","value":9}]}`)
	for _, lanes := range []int{2, 4, 8, 16} {
		l1 := laneFor(bodyA1, lanes)
		l2 := laneFor(bodyA2, lanes)
		if l1 != l2 {
			t.Errorf("lanes=%d: same source_type routed to different lanes %d != %d", lanes, l1, l2)
		}
		if l1 < 0 || l1 >= lanes {
			t.Errorf("lanes=%d: lane %d out of range", lanes, l1)
		}
	}
}

// TestLaneForSerialMode: lanes<=1 always maps to the single lane 0 — this is
// the inert default that reproduces the original serial behavior.
func TestLaneForSerialMode(t *testing.T) {
	for _, body := range []string{
		`{"source_type":"go"}`, `{"source_type":""}`, `{"source_type":"refactored"}`,
	} {
		if got := laneFor([]byte(body), 1); got != 0 {
			t.Errorf("laneFor(%s, 1) = %d, want 0", body, got)
		}
		if got := laneFor([]byte(body), 0); got != 0 {
			t.Errorf("laneFor(%s, 0) = %d, want 0", body, got)
		}
	}
}

// TestLaneForFansOut confirms distinct source_types can reach distinct lanes
// (otherwise the pool would give no parallelism). With the three real
// source_types and a modest lane count we expect >1 distinct lane.
func TestLaneForFansOut(t *testing.T) {
	seen := map[int]bool{}
	for _, st := range []string{"", "go", "refactored"} {
		body := []byte(`{"source_type":"` + st + `","metrics":[]}`)
		seen[laneFor(body, 8)] = true
	}
	if len(seen) < 2 {
		t.Errorf("expected the 3 source_types to fan out across >1 lane, got %d distinct", len(seen))
	}
}
