package tenantprofile

import (
	"strings"
	"testing"
)

// TestProfileDerivedValidation checks the resolved-form DerivedRule validation
// that guards the profile the runtime deriver + register loader consume.
func TestProfileDerivedValidation(t *testing.T) {
	base := func(r DerivedRule) *Profile {
		return &Profile{
			TenantPrefix:    "T/SP",
			MetricTemplates: MetricTemplates{Member: []TemplateEntry{{Leaf: "/Status/MachSpeed", Type: "double"}}},
			Derived:         []DerivedRule{r},
		}
	}
	cases := []struct {
		name    string
		rule    DerivedRule
		wantErr string
	}{
		{
			name: "valid integral",
			rule: DerivedRule{Segment: "/L5/FLEXO", Emit: []string{"/L5/FLEXO/Admin/ProdConsumedCount/61/Unit"}, Type: "double",
				Integral: &IntegralSource{Source: "/L5/FLEXO/Status/CurMachSpeed", Conversion: 1}},
		},
		{
			name: "valid sum",
			rule: DerivedRule{Segment: "/L5/PTH", Emit: []string{"/L5/PTH/Admin/ProdConsumedCount/70/Unit"}, Type: "double",
				Sum: &SumSource{Addends: []string{"/L5/PTH/Status/A", "/L5/PTH/Status/B"}}},
		},
		{
			name:    "both set",
			rule:    DerivedRule{Segment: "/x", Emit: []string{"/x/c"}, Type: "double", Integral: &IntegralSource{Source: "/x/s"}, Sum: &SumSource{Addends: []string{"/x/a", "/x/b"}}},
			wantErr: "exactly one of {integral, sum}",
		},
		{
			name:    "empty emit",
			rule:    DerivedRule{Segment: "/x", Type: "double", Integral: &IntegralSource{Source: "/x/s"}},
			wantErr: "emit must list",
		},
		{
			name:    "bad type",
			rule:    DerivedRule{Segment: "/x", Emit: []string{"/x/c"}, Type: "nope", Integral: &IntegralSource{Source: "/x/s"}},
			wantErr: "must be double|float|long|int|bool|string",
		},
		{
			name:    "sum one addend",
			rule:    DerivedRule{Segment: "/x", Emit: []string{"/x/c"}, Type: "double", Sum: &SumSource{Addends: []string{"/x/a"}}},
			wantErr: "at least two suffixes",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := base(tc.rule).Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("want valid, got %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}
