package deriver

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// fakeMetrics records the deriver's observability calls (ADR-0059 §1.1).
type fakeMetrics struct {
	errors  []string // "segment:kind"
	emitted []string // "segment"
}

func (m *fakeMetrics) DeriveError(segment, kind string) {
	m.errors = append(m.errors, segment+":"+kind)
}
func (m *fakeMetrics) DeriveEmitted(segment string) { m.emitted = append(m.emitted, segment) }

// TestExprMetrics is the ADR-0059 §1.1 proof: a healthy expr bumps emitted; a
// non-finite (÷0) result bumps errors with the segment + kind — so a silently
// dropped customization is now an operator signal, not invisible.
func TestExprMetrics(t *testing.T) {
	const a, b = "/M/A", "/M/B"
	d := New(&tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/M", Emit: []string{"/M/Out/1/Unit"}, Type: "double",
			Expr: &tenantprofile.ExprSource{Expr: "a / b", Vars: map[string]string{"a": a, "b": b}},
		}},
	})
	m := &fakeMetrics{}
	d.SetMetrics(m)

	// Healthy batch: a=10, b=2 → 5, one emitted.
	d.Process([]rawtag.RawTag{speed(a, 10, 1000), speed(b, 2, 1000)})
	if len(m.emitted) != 1 || m.emitted[0] != "/M" {
		t.Fatalf("emitted = %v, want [/M]", m.emitted)
	}
	if len(m.errors) != 0 {
		t.Fatalf("no error expected on a healthy batch, got %v", m.errors)
	}

	// ÷0 batch: b=0 → non-finite → dropped + an error signal (segment + kind).
	d.Process([]rawtag.RawTag{speed(b, 0, 2000)})
	if len(m.errors) != 1 || m.errors[0] != "/M:non_finite" {
		t.Fatalf("errors = %v, want [/M:non_finite]", m.errors)
	}
	// still only the one healthy emit (the ÷0 batch produced nothing).
	if len(m.emitted) != 1 {
		t.Fatalf("emitted count = %d, want 1 (÷0 emits nothing)", len(m.emitted))
	}
}

// TestExprMetrics_NilSafe: a deriver with no metrics sink must not panic.
func TestExprMetrics_NilSafe(t *testing.T) {
	d := New(&tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/M", Emit: []string{"/M/Out/1/Unit"}, Type: "double",
			Expr: &tenantprofile.ExprSource{Expr: "a + 1", Vars: map[string]string{"a": "/M/A"}},
		}},
	})
	// no SetMetrics — must be a no-op, not a nil deref.
	synth, _ := d.Process([]rawtag.RawTag{speed("/M/A", 4, 1000)})
	if v, ok := findEmit(synth, "/M/Out/1/Unit"); !ok || v != 5 {
		t.Fatalf("nil-safe emit: got %v ok=%v, want 5", v, ok)
	}
}
