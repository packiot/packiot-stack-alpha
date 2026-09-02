package clientdescriptor

import (
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// derivedValidBaseYAML is a minimal, valid descriptor with ONE member (FLEXO,
// count_index 61). Each case below parses it, then grafts a `derived:` block onto
// the member and re-Validates — so the cases isolate the DerivedMetric rules.
const derivedValidBaseYAML = `
tenant: ACME
enterprise_id: 42
canonical:
  prefix: ACME/SP
mapping:
  count_index_default_mode: equipment_id
metric_templates:
  member:
    - {leaf: "/Status/MachSpeed", type: double}
equipment:
  - topic: ACME/SP/L5/FLEXO
    id_equipment: 5001
    tp_equipment: 1
    id_unit: 5001
    count_index: {value: 61, confidence: confirmed}
`

func integralSrc(source string, conv, clampMin, maxRate float64) *tenantprofile.IntegralSource {
	return &tenantprofile.IntegralSource{Source: source, Conversion: conv, ClampMin: clampMin, MaxRate: maxRate}
}

func sumSrc(addends ...string) *tenantprofile.SumSource {
	return &tenantprofile.SumSource{Addends: addends}
}

func TestDerivedMetric_Validation(t *testing.T) {
	const speed = "/Status/CurMachSpeed"
	const emit = "/Admin/ProdConsumedCount/{idx}/Unit"

	cases := []struct {
		name    string
		derived []DerivedMetric
		wantErr string // substring; "" = must pass
	}{
		{
			name:    "valid integral",
			derived: []DerivedMetric{{Emit: []string{emit}, Type: "double", Integral: integralSrc(speed, 1, 0, 0)}},
		},
		{
			name:    "valid sum (two addends)",
			derived: []DerivedMetric{{Emit: []string{emit}, Type: "double", Sum: sumSrc("/Status/CountA", "/Status/CountB")}},
		},
		{
			name:    "both integral and sum → one-of violation",
			derived: []DerivedMetric{{Emit: []string{emit}, Type: "double", Integral: integralSrc(speed, 1, 0, 0), Sum: sumSrc("/Status/CountA", "/Status/CountB")}},
			wantErr: "exactly one of {integral, sum}",
		},
		{
			name:    "neither integral nor sum → one-of violation",
			derived: []DerivedMetric{{Emit: []string{emit}, Type: "double"}},
			wantErr: "exactly one of {integral, sum}",
		},
		{
			name:    "empty emit",
			derived: []DerivedMetric{{Type: "double", Integral: integralSrc(speed, 1, 0, 0)}},
			wantErr: "emit must list",
		},
		{
			name:    "bad type",
			derived: []DerivedMetric{{Emit: []string{emit}, Type: "widget", Integral: integralSrc(speed, 1, 0, 0)}},
			wantErr: `type="widget"`,
		},
		{
			name:    "sum with one addend",
			derived: []DerivedMetric{{Emit: []string{emit}, Type: "double", Sum: sumSrc("/Status/CountA")}},
			wantErr: "at least two suffixes",
		},
		{
			name:    "integral without source",
			derived: []DerivedMetric{{Emit: []string{emit}, Type: "double", Integral: integralSrc("", 1, 0, 0)}},
			wantErr: "integral.source is required",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d, err := Parse([]byte(derivedValidBaseYAML))
			if err != nil {
				t.Fatalf("base descriptor must parse: %v", err)
			}
			d.Equipment[0].Derived = tc.derived
			err = d.Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("want valid, got error: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("want error containing %q, got nil", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErr)
			}
		})
	}
}
