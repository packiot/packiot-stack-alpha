package bake

import "testing"

// TestIdentityMatch pins the F2/F3 identity tolerance contract: count exact,
// sum fields within identityTol (1%). Real divergences (the historical ones were
// ≥20%) must still fail; the measured in-flight residual (eq51 gross 0.35%) must
// pass; running_time is event-derived and stays byte-exact so a running_time
// gap of any real size fails.
func TestIdentityMatch(t *testing.T) {
	cases := []struct {
		name     string
		a, b     string
		countTol bool
		want     bool
	}{
		{"byte-identical", "520|505279000.000|1643940.0", "520|505279000.000|1643940.0", false, true},
		{"gross within band (0.35%)", "520|505279000|1643940", "520|503523000|1643940", false, true},
		{"gross beyond band (~21%)", "520|505279000|1643940", "520|400000000|1643940", false, false},
		{"count differs (exact surface)", "520|505279000|1643940", "519|505279000|1643940", false, false},
		{"running_time gap (~19%)", "520|505279000|2032680", "520|505279000|1643940", false, false},
		{"field-count differs", "520|505279000", "520|505279000|1643940", false, false},
		{"zeros", "0|0|0", "0|0|0", false, true},
		{"gross exactly at 1%", "520|100000000|10", "520|101000000|10", false, true}, // rel = 1000000/101000000 = 0.99%
		{"gross just over 1%", "520|100000000|10", "520|102000000|10", false, false}, // rel = 2000000/102000000 = 1.96%
		{"two-field PO surface within band", "300|123456789", "300|123400000", false, true},
		// countTolerant (raw equipment_values surface): count within band passes, beyond fails.
		{"raw count within band (0.04%)", "54689|1817080000|1844530000", "54709|1818400000|1845870000", true, true},
		{"raw count beyond band (~10%)", "54689|1817080000|1844530000", "60000|1817080000|1844530000", true, false},
		{"raw count tolerant but sum beyond band", "54689|1817080000|1844530000", "54709|1817080000|2100000000", true, false},
	}
	for _, c := range cases {
		got, detail := IdentityMatch(c.a, c.b, c.countTol)
		if got != c.want {
			t.Errorf("%s: IdentityMatch(%q, %q, %v) = %v (detail=%q), want %v", c.name, c.a, c.b, c.countTol, got, detail, c.want)
		}
	}
}
