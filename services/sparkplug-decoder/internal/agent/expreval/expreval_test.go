package expreval

import (
	"math"
	"testing"
)

// TestCompileAndEval: a well-formed expression over declared vars evaluates.
func TestCompileAndEval(t *testing.T) {
	p, err := Compile("gross - net", []string{"gross", "net"})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	got, err := Eval(p, map[string]float64{"gross": 100, "net": 88})
	if err != nil {
		t.Fatalf("eval: %v", err)
	}
	if got != 12 {
		t.Fatalf("gross-net: got %v, want 12", got)
	}
}

// TestUndefinedVarIsCompileError: the closed environment rejects any identifier
// not in the declared var set — a rule can only read tags it declared.
func TestUndefinedVarIsCompileError(t *testing.T) {
	if _, err := Compile("gross - sneaky", []string{"gross"}); err == nil {
		t.Fatal("expected compile error for undeclared var 'sneaky', got nil")
	}
}

// TestNoIOFunctions: expr-lang exposes no I/O; a call to something like a file or
// network builtin must not compile (there is none to call).
func TestNoIOFunctions(t *testing.T) {
	// `os` / `http` etc. are simply not in the environment → undefined identifier.
	if _, err := Compile("os.Getenv(\"X\")", []string{}); err == nil {
		t.Fatal("expected compile error: no I/O identifiers should be in scope")
	}
}

// TestMissingVarBindsZero: a declared var absent from the eval env binds to 0
// (the caller gates on 'all seen' before trusting the result).
func TestMissingVarBindsZero(t *testing.T) {
	p, err := Compile("a + b", []string{"a", "b"})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	got, err := Eval(p, map[string]float64{"a": 5}) // b missing → 0
	if err != nil {
		t.Fatalf("eval: %v", err)
	}
	if got != 5 {
		t.Fatalf("missing var: got %v, want 5", got)
	}
}

// TestDivisionAndFloat: non-integer arithmetic (unit conversion) is preserved as
// a float; the deriver decides whether to floor based on the emit type.
func TestDivisionAndFloat(t *testing.T) {
	p, err := Compile("speed / 60.0", []string{"speed"})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	got, err := Eval(p, map[string]float64{"speed": 90})
	if err != nil {
		t.Fatalf("eval: %v", err)
	}
	if math.Abs(got-1.5) > 1e-9 {
		t.Fatalf("90/60: got %v, want 1.5", got)
	}
}

// TestDivByZeroIsErrorNotPanic: a divide-by-zero must degrade to an error the
// caller can drop, never a panic that could take down the shared agent.
func TestDivByZeroIsErrorNotPanic(t *testing.T) {
	p, err := Compile("a / b", []string{"a", "b"})
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	got, err := Eval(p, map[string]float64{"a": 1, "b": 0})
	// Go float division by zero yields +Inf (no panic); some expr paths may error.
	// Either way the process must survive — assert no panic reached us (we got here)
	// and, if no error, the result is a non-finite sentinel the deriver can guard.
	if err == nil && !math.IsInf(got, 0) && !math.IsNaN(got) {
		t.Fatalf("1/0: expected error or non-finite, got %v", got)
	}
}
