package rollupshadow

import "testing"

func TestQueryQuotesTheSchema(t *testing.T) {
	cases := map[string]string{
		"silver":     `SELECT live_rows, drained_minutes, drained_hours, remaining FROM "silver".rollup_tick()`,
		`we"ird`:     `SELECT live_rows, drained_minutes, drained_hours, remaining FROM "we""ird".rollup_tick()`,
		"Mixed Case": `SELECT live_rows, drained_minutes, drained_hours, remaining FROM "Mixed Case".rollup_tick()`,
	}
	for schema, want := range cases {
		if got := Query(schema); got != want {
			t.Errorf("Query(%q) = %q, want %q", schema, got, want)
		}
	}
}
