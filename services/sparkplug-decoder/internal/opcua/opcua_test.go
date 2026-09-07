package opcua

import "testing"

func TestCoerce(t *testing.T) {
	cases := []struct {
		name string
		v    any
		ty   Type
		want float64
		ok   bool
	}{
		{"float64→float", 120.5, TypeFloat, 120.5, true},
		{"int32→int", int32(42000), TypeInt, 42000, true},
		{"uint16→int", uint16(6), TypeInt, 6, true},
		{"bool true→1", true, TypeBool, 1, true},
		{"bool false→0", false, TypeBool, 0, true},
		{"numeric string→float", "123.4", TypeString, 123.4, true},
		{"non-numeric string→err", "n/a", TypeString, 0, false},
		{"nil value→err", nil, TypeFloat, 0, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := coerce(tc.v, tc.ty)
			if ok != tc.ok || (ok && got != tc.want) {
				t.Fatalf("coerce(%v,%v) = %v,%v want %v,%v", tc.v, tc.ty, got, ok, tc.want, tc.ok)
			}
		})
	}
}

func TestPollerSample(t *testing.T) {
	const prefix = "CPACK/PLANT/LINE1/MACH_1/MACH_1"
	tags := []Tag{
		{Metric: prefix + "/Admin/ProdProcessedCount/1/Unit", Alias: 1, NodeID: "ns=2;s=Count", Type: TypeInt},
		{Metric: prefix + "/Status/MachSpeed", Alias: 2, NodeID: "ns=2;s=Speed", Type: TypeFloat, Scale: 0.1},
		{Metric: prefix + "/Status/StateCurrent", Alias: 3, NodeID: "ns=2;s=State", Type: TypeInt, Long: true},
		{Metric: prefix + "/Status/Running", Alias: 4, NodeID: "ns=2;s=Run", Type: TypeBool},
	}
	p, err := NewPoller(tags)
	if err != nil {
		t.Fatalf("NewPoller: %v", err)
	}

	// Fake server: returns typed values in the SAME order it was asked.
	read := func(ids []string) ([]any, error) {
		if len(ids) != 4 || ids[0] != "ns=2;s=Count" {
			t.Fatalf("unexpected node id batch: %v", ids)
		}
		return []any{int32(42000), float64(1200), int16(6), true}, nil
	}

	// NBIRTH: names present.
	ms, err := p.Sample(read, true)
	if err != nil {
		t.Fatalf("Sample birth: %v", err)
	}
	if len(ms) != 4 {
		t.Fatalf("want 4 metrics, got %d", len(ms))
	}
	if ms[0].Name != tags[0].Metric || ms[0].Double != 42000 {
		t.Fatalf("count = name=%q val=%v", ms[0].Name, ms[0].Double)
	}
	if ms[1].Double != 120.0 { // 1200 * 0.1
		t.Fatalf("machspeed = %v want 120", ms[1].Double)
	}
	if !ms[2].IsLong || ms[2].Long != 6 {
		t.Fatalf("state = long=%v val=%d want long 6", ms[2].IsLong, ms[2].Long)
	}
	if ms[3].Double != 1 {
		t.Fatalf("running = %v want 1", ms[3].Double)
	}

	// NDATA: names omitted (alias-only).
	ms2, err := p.Sample(read, false)
	if err != nil {
		t.Fatalf("Sample data: %v", err)
	}
	if ms2[0].Name != "" {
		t.Fatalf("NDATA must omit names, got %q", ms2[0].Name)
	}
	if ms2[0].Alias != 1 {
		t.Fatalf("NDATA must carry alias, got %d", ms2[0].Alias)
	}
}

func TestPollerUnreadableNode(t *testing.T) {
	tags := []Tag{{Metric: "T/x", Alias: 1, NodeID: "ns=2;s=X", Type: TypeFloat}}
	p, _ := NewPoller(tags)
	// Server returned nil for the node (bad status) — must surface as an error,
	// not a silent zero.
	_, err := p.Sample(func([]string) ([]any, error) { return []any{nil}, nil }, false)
	if err == nil {
		t.Fatal("unreadable node must error")
	}
}

func TestNewPollerValidation(t *testing.T) {
	if _, err := NewPoller(nil); err == nil {
		t.Fatal("empty tags must error")
	}
	dup := []Tag{
		{Metric: "a", Alias: 1, NodeID: "ns=2;s=a", Type: TypeFloat},
		{Metric: "b", Alias: 1, NodeID: "ns=2;s=b", Type: TypeFloat},
	}
	if _, err := NewPoller(dup); err == nil {
		t.Fatal("duplicate alias must error")
	}
	if _, err := NewPoller([]Tag{{Metric: "x", Alias: 1, NodeID: "", Type: TypeFloat}}); err == nil {
		t.Fatal("empty node id must error")
	}
}
