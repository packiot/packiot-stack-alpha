package bake

import "testing"

// TestIdentityMatch pins the F2/F3 identity tolerance contract: count exact,
// sum fields within identityTol (1%). Real divergences (the historical ones were
// ≥20%) must still fail; the measured in-flight residual (eq51 gross 0.35%) must
// pass; running_time is event-derived and stays byte-exact so a running_time
// gap of any real size fails.
func TestIdentityMatch(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		want bool
	}{
		{"byte-identical", "520|505279000.000|1643940.0", "520|505279000.000|1643940.0", true},
		{"gross within band (0.35%)", "520|505279000|1643940", "520|503523000|1643940", true},
		{"gross beyond band (~21%)", "520|505279000|1643940", "520|400000000|1643940", false},
		{"count differs", "520|505279000|1643940", "519|505279000|1643940", false},
		{"running_time gap (~19%)", "520|505279000|2032680", "520|505279000|1643940", false},
		{"field-count differs", "520|505279000", "520|505279000|1643940", false},
		{"zeros", "0|0|0", "0|0|0", true},
		{"gross exactly at 1%", "520|100000000|10", "520|101000000|10", true}, // rel = 1000000/101000000 = 0.99%
		{"gross just over 1%", "520|100000000|10", "520|102000000|10", false}, // rel = 2000000/102000000 = 1.96%
		{"two-field PO surface within band", "300|123456789", "300|123400000", true},
	}
	for _, c := range cases {
		got, detail := identityMatch(c.a, c.b)
		if got != c.want {
			t.Errorf("%s: identityMatch(%q, %q) = %v (detail=%q), want %v", c.name, c.a, c.b, got, detail, c.want)
		}
	}
}
