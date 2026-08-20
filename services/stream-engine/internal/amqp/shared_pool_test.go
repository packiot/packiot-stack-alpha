package amqp

import (
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"
)

// Strategy D — the tenant-set bookkeeping the dynamic-discovery loop relies on
// to keep the reconnect topology in sync with what we actually consume.
func TestTenantSetAddRemoveSnapshot(t *testing.T) {
	c := &Consumer{tenants: []string{"cpack"}}

	// Snapshot is a copy — mutating it must not touch the source.
	snap := c.tenantSnapshot()
	snap[0] = "mutated"
	if got := c.tenantSnapshot(); got[0] != "cpack" {
		t.Fatalf("snapshot is not a copy: got %v", got)
	}

	// addTenant is idempotent.
	c.addTenant("acme")
	c.addTenant("acme")
	if got := c.tenantSnapshot(); len(got) != 2 {
		t.Fatalf("expected 2 tenants after idempotent add, got %v", got)
	}

	// removeTenant drops only the target, order-independent.
	c.removeTenant("cpack")
	got := c.tenantSnapshot()
	if len(got) != 1 || got[0] != "acme" {
		t.Fatalf("expected only [acme] after remove, got %v", got)
	}

	// Removing an absent tenant is a no-op.
	c.removeTenant("ghost")
	if got := c.tenantSnapshot(); len(got) != 1 {
		t.Fatalf("removing absent tenant changed set: %v", got)
	}
}

// isPreconditionFailed must recognise the AMQP 406 a mismatched immutable-arg
// redeclare yields (the SAC migration signal) and reject everything else.
func TestIsPreconditionFailed(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"406 precondition failed", &amqp.Error{Code: amqp.PreconditionFailed, Reason: "inequivalent arg 'x-single-active-consumer'"}, true},
		{"403 access refused", &amqp.Error{Code: amqp.AccessRefused}, false},
		{"nil", nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isPreconditionFailed(tc.err); got != tc.want {
				t.Fatalf("isPreconditionFailed(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}
