// Package expreval is the sandboxed arithmetic evaluator behind the agent's
// declarative DERIVE "expr" rule (ADR-0058 Tier 1). It wraps expr-lang/expr so
// the rest of the agent never touches the evaluator directly and the sandbox
// policy lives in exactly one place.
//
// Why a general expression at all: the closed-algebra derive shapes (integral,
// sum) and the fixed counter_derive identities cannot express per-client math
// like scrap = DW0 − DW4, merge two PLCs into one tag, unit conversion, or a
// deadband. ADR-0058 adds one general primitive here rather than a whole
// customization platform, and keeps the descriptor pipeline as the governance
// spine. ADR-0050's reserved plc.types[].derive is the first customer.
//
// Sandbox guarantees (why this is safe to run in the shared agent):
//   - PURE: expr-lang has no I/O and no user-defined loops; a program is bounded
//     by the expression's own size, so there is no unbounded execution to time out.
//   - CLOSED ENV: Compile fixes the free-variable set to the declared vars (all
//     float64). Any other identifier is a COMPILE error, so a rule referencing a
//     tag it never declared is rejected at load/generate time, not at runtime.
//   - PANIC-ISOLATED: Eval recovers any panic and returns an error. A malformed
//     rule degrades to a dropped tag for that equipment — it can NEVER crash the
//     shared agent (the ADR-0057 uncaught-throw-took-down-the-process lesson).
package expreval

import (
	"fmt"

	"github.com/expr-lang/expr"
	"github.com/expr-lang/expr/vm"
)

// Program is a compiled, sandboxed expression over a fixed set of float64 vars.
// It is safe for repeated Eval calls; the compiled bytecode is immutable and the
// per-call environment is supplied to Eval.
type Program struct {
	prog *vm.Program
	vars []string
}

// Compile compiles code into a Program whose ONLY free variables are vars (each
// bound to a float64 at Eval time) and whose result is coerced to float64. Any
// identifier in code that is not in vars is a compile error (closed environment),
// so a rule can only read the tags it explicitly declared. Compile is called at
// descriptor-validate / profile-load time, so a bad expression fails fast, off
// the hot path.
func Compile(code string, vars []string) (*Program, error) {
	env := make(map[string]any, len(vars))
	for _, v := range vars {
		env[v] = float64(0)
	}
	prog, err := expr.Compile(code,
		expr.Env(env),     // closed env: only vars are in scope
		expr.AsFloat64(),  // type-check + coerce the result to float64
	)
	if err != nil {
		return nil, err
	}
	return &Program{prog: prog, vars: append([]string(nil), vars...)}, nil
}

// Eval runs p against env (var name → value) and returns the float64 result. It
// recovers any panic so a bad expression can never take down the caller: a panic
// or a non-numeric result becomes an error the caller degrades to a dropped tag.
// Missing vars bind to 0 (a var declared but not yet seen this batch); the caller
// is expected to gate on "all vars seen" before relying on the result.
func Eval(p *Program, env map[string]float64) (result float64, err error) {
	defer func() {
		if r := recover(); r != nil {
			result, err = 0, fmt.Errorf("expr eval panic: %v", r)
		}
	}()
	m := make(map[string]any, len(p.vars))
	for _, v := range p.vars {
		m[v] = env[v] // absent → zero value 0.0
	}
	out, err := expr.Run(p.prog, m)
	if err != nil {
		return 0, err
	}
	f, ok := out.(float64)
	if !ok {
		return 0, fmt.Errorf("expr result type %T is not float64", out)
	}
	return f, nil
}

// Vars returns the declared variable names (copy).
func (p *Program) Vars() []string { return append([]string(nil), p.vars...) }
