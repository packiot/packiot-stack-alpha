package deriver

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// exprProfile builds a single-rule expr profile. typ selects flooring behavior.
func exprProfile(segment, code, typ string, emit []string, vars map[string]string) *tenantprofile.Profile {
	return &tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment: segment,
			Emit:    emit,
			Type:    typ,
			Expr:    &tenantprofile.ExprSource{Expr: code, Vars: vars},
		}},
	}
}

// TestExprScrapDW0MinusDW4: the canonical Bispharma need — scrap = gross − net —
// expressed declaratively, evaluated in one envelope.
func TestExprScrapDW0MinusDW4(t *testing.T) {
	const gross = "/L5/PTH/Status/DW0"
	const net = "/L5/PTH/Status/DW4"
	const emit = "/L5/PTH/Admin/ProdDefectiveCount/61/Unit"
	d := New(exprProfile("/L5/PTH", "gross - net", "long",
		[]string{emit}, map[string]string{"gross": gross, "net": net}))

	synth, consumed := d.Process([]rawtag.RawTag{
		speed(gross, 100, 1000),
		speed(net, 88, 1000),
	})
	if v, ok := findEmit(synth, emit); !ok || v != 12 {
		t.Fatalf("scrap=gross-net: got %v ok=%v, want 12", v, ok)
	}
	// Expr inputs are NOT consumed (no sum rules → consumed stays nil): DW0/DW4
	// keep flowing raw.
	if consumed != nil {
		t.Fatalf("expr inputs must not be consumed, got %v", consumed)
	}
}

// TestExprMergeTwoPLCsAcrossEnvelopes: "merge two PLCs into one tag" — the two
// sources arrive in SEPARATE envelopes; the rule latches each and (re)emits once
// both have been seen, then updates when either input changes.
func TestExprMergeTwoPLCsAcrossEnvelopes(t *testing.T) {
	const a = "/LINE/PLC_A/Count"
	const b = "/LINE/PLC_B/Count"
	const emit = "/LINE/Merged/Count/1/Unit"
	d := New(exprProfile("/LINE", "a + b", "long",
		[]string{emit}, map[string]string{"a": a, "b": b}))

	// Envelope 1: only A → NOT warmed up → no emit (a partial merge is garbage).
	synth, _ := d.Process([]rawtag.RawTag{speed(a, 10, 1000)})
	if _, ok := findEmit(synth, emit); ok {
		t.Fatal("must not emit before every input has been seen")
	}
	// Envelope 2: B arrives → both seen → emit 10+5=15.
	synth, _ = d.Process([]rawtag.RawTag{speed(b, 5, 2000)})
	if v, ok := findEmit(synth, emit); !ok || v != 15 {
		t.Fatalf("merge after both seen: got %v ok=%v, want 15", v, ok)
	}
	// Envelope 3: A updates to 30, B latched at 5 → emit 35 with the new ts.
	synth, _ = d.Process([]rawtag.RawTag{speed(a, 30, 3000)})
	v, ok := findEmit(synth, emit)
	if !ok || v != 35 {
		t.Fatalf("merge after A update: got %v ok=%v, want 35", v, ok)
	}
	if synth[len(synth)-1].TsMillis != 3000 {
		t.Fatalf("emit ts should be the updating input's ts 3000, got %d", synth[len(synth)-1].TsMillis)
	}
}

// TestExprTypeFlooring: a count type (long) floors the result; an analog type
// (double, e.g. a unit conversion / deadband) keeps its fraction.
func TestExprTypeFlooring(t *testing.T) {
	const src = "/M/Speed"
	// long: 90 * 0.5 = 45.0 (already integer) — use an odd factor to force a fraction.
	dLong := New(exprProfile("/M", "s * 0.5", "long",
		[]string{"/M/Out/1/Unit"}, map[string]string{"s": src}))
	synth, _ := dLong.Process([]rawtag.RawTag{speed(src, 91, 1000)}) // 45.5 → floor 45
	if v, _ := findEmit(synth, "/M/Out/1/Unit"); v != 45 {
		t.Fatalf("long type must floor 45.5→45, got %v", v)
	}

	dDouble := New(exprProfile("/M", "s * 0.5", "double",
		[]string{"/M/Out/1/Unit"}, map[string]string{"s": src}))
	synth, _ = dDouble.Process([]rawtag.RawTag{speed(src, 91, 1000)}) // 45.5 kept
	if v, _ := findEmit(synth, "/M/Out/1/Unit"); v != 45.5 {
		t.Fatalf("double type must keep 45.5, got %v", v)
	}
}

// TestExprDivByZeroDropped: an input that makes the expression non-finite (÷0 →
// ±Inf) drops the tag for that batch — never a garbage count, never a crash.
func TestExprDivByZeroDropped(t *testing.T) {
	const a = "/M/A"
	const b = "/M/B"
	const emit = "/M/Ratio/1/Unit"
	d := New(exprProfile("/M", "a / b", "double",
		[]string{emit}, map[string]string{"a": a, "b": b}))
	synth, _ := d.Process([]rawtag.RawTag{speed(a, 10, 1000), speed(b, 0, 1000)})
	if _, ok := findEmit(synth, emit); ok {
		t.Fatal("÷0 result is non-finite and must be dropped, not emitted")
	}
	// A subsequent valid batch self-heals.
	synth, _ = d.Process([]rawtag.RawTag{speed(b, 2, 2000)}) // a latched at 10 → 5
	if v, ok := findEmit(synth, emit); !ok || v != 5 {
		t.Fatalf("self-heal after valid divisor: got %v ok=%v, want 5", v, ok)
	}
}

// TestExprFaultIsolationBadRuleSkipped: if a rule somehow reaches New with an
// uncompilable expression (bypassing validate), New SKIPS it and the other rules
// still work — one bad rule never disables a tenant's good ones, never panics.
func TestExprFaultIsolationBadRuleSkipped(t *testing.T) {
	const good = "/M/Good/1/Unit"
	prof := &tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{
			{Segment: "/M", Emit: []string{"/M/Bad/1/Unit"}, Type: "long",
				Expr: &tenantprofile.ExprSource{Expr: "a +", Vars: map[string]string{"a": "/M/A"}}}, // syntax error
			{Segment: "/M", Emit: []string{good}, Type: "long",
				Expr: &tenantprofile.ExprSource{Expr: "a * 2", Vars: map[string]string{"a": "/M/A"}}},
		},
	}
	d := New(prof) // must not panic
	synth, _ := d.Process([]rawtag.RawTag{speed("/M/A", 7, 1000)})
	if v, ok := findEmit(synth, good); !ok || v != 14 {
		t.Fatalf("good rule must still emit 14 despite a bad sibling, got %v ok=%v", v, ok)
	}
}

// TestExprConsumeDropsInput proves the ADR-0058 P1.4b consume path: a var listed
// in Expr.Consume is folded into the expression AND dropped from raw passthrough
// (never republished), while a non-consumed var (a real published count) passes
// through.
func TestExprConsumeDropsInput(t *testing.T) {
	const a = "/L/A" // a real published count — NOT consumed
	const b = "/L/B" // a synthetic derive-input sensor — consumed
	const emit = "/L/Out/1/Unit"
	d := New(&tenantprofile.Profile{
		TenantPrefix: "T",
		Derived: []tenantprofile.DerivedRule{{
			Segment: "/L", Emit: []string{emit}, Type: "long",
			Expr: &tenantprofile.ExprSource{
				Expr: "a + b", Vars: map[string]string{"a": a, "b": b}, Consume: []string{"b"},
			},
		}},
	})
	synth, consumed := d.Process([]rawtag.RawTag{speed(a, 10, 1000), speed(b, 5, 1000)})
	if v, ok := findEmit(synth, emit); !ok || v != 15 {
		t.Fatalf("out = a+b: got %v ok=%v, want 15", v, ok)
	}
	if consumed == nil || !consumed[b] {
		t.Fatalf("b (synthetic input) must be consumed, got consumed=%v", consumed)
	}
	if consumed[a] {
		t.Fatalf("a (real published count) must NOT be consumed")
	}
}

// TestExprValidateCompileCheck: a bad expression is rejected at profile validate
// (fail-fast at load, off the hot path).
func TestExprValidateCompileCheck(t *testing.T) {
	bad := tenantprofile.DerivedRule{
		Segment: "/M", Emit: []string{"/M/X/1/Unit"}, Type: "long",
		Expr: &tenantprofile.ExprSource{Expr: "a - undeclared", Vars: map[string]string{"a": "/M/A"}},
	}
	prof := &tenantprofile.Profile{TenantPrefix: "T", Derived: []tenantprofile.DerivedRule{bad}}
	if err := prof.Validate(); err == nil {
		t.Fatal("expected validate to reject an expr referencing an undeclared var")
	}
}
