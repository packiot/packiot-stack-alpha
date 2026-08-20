package handlers

import (
	"errors"
	"fmt"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// TestShouldSwallowShadowErr is the G1 defensive backstop: a write to the
// shadow_go_port comparator schema that fails because the schema is absent
// (42P01 undefined_table / 3F000 invalid_schema_name) on a single-flow prod
// stack must be swallowed so the delivery ACKs instead of nack→DLX→redeliver
// forever (a poison storm that would starve the production "" legs). A public
// (production/refactored) error, or any non-missing-relation error, must still
// propagate so real ingest failures nack + retry.
func TestShouldSwallowShadowErr(t *testing.T) {
	undefinedTable := &pgconn.PgError{Code: "42P01", Message: `relation "shadow_go_port.equipment_values" does not exist`}
	invalidSchema := &pgconn.PgError{Code: "3F000", Message: `schema "shadow_go_port" does not exist`}
	inFailedTx := &pgconn.PgError{Code: "25P02", Message: "current transaction is aborted"}
	uniqueViol := &pgconn.PgError{Code: "23505", Message: "duplicate key value"}

	cases := []struct {
		name   string
		schema string
		err    error
		want   bool
	}{
		{"shadow schema + 42P01 → swallow", "shadow_go_port", undefinedTable, true},
		{"shadow schema + 42P01 wrapped → swallow", "shadow_go_port", fmt.Errorf("equipment_values upsert: %w", undefinedTable), true},
		{"shadow schema + 3F000 → swallow", "shadow_go_port", invalidSchema, true},
		{"shadow schema + 25P02 (follower) → propagate", "shadow_go_port", inFailedTx, false},
		{"shadow schema + real error (unique) → propagate", "shadow_go_port", uniqueViol, false},
		{"shadow schema + nil error → propagate (nothing to swallow)", "shadow_go_port", nil, false},
		{"public schema + 42P01 → propagate (production stays fatal)", "public", undefinedTable, false},
		{"public schema + 42P01 wrapped → propagate", "public", fmt.Errorf("x: %w", undefinedTable), false},
		{"public schema + real error → propagate", "public", uniqueViol, false},
		{"shadow schema + non-pg error → propagate", "shadow_go_port", errors.New("connection reset"), false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldSwallowShadowErr(tc.schema, tc.err); got != tc.want {
				t.Fatalf("shouldSwallowShadowErr(%q, %v) = %v, want %v", tc.schema, tc.err, got, tc.want)
			}
		})
	}
}

// TestIsMissingRelation checks the SQLSTATE match is structured (via
// pgconn.PgError), not string-based — a table literally named
// "...does not exist..." with a benign SQLSTATE must NOT false-positive.
func TestIsMissingRelation(t *testing.T) {
	if !isMissingRelation(&pgconn.PgError{Code: "42P01"}) {
		t.Error("42P01 should be a missing relation")
	}
	if !isMissingRelation(&pgconn.PgError{Code: "3F000"}) {
		t.Error("3F000 should be a missing relation")
	}
	if isMissingRelation(&pgconn.PgError{Code: "23505", Message: "does not exist"}) {
		t.Error("23505 must NOT match even if the message contains 'does not exist' (no string matching)")
	}
	if isMissingRelation(errors.New("relation shadow_go_port.equipment_values does not exist")) {
		t.Error("a plain error must NOT match — SQLSTATE match only, not string matching")
	}
	if isMissingRelation(nil) {
		t.Error("nil must not match")
	}
}
