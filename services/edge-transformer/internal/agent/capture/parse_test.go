package capture

import "testing"

func TestParseObservation(t *testing.T) {
	// The CPACK count families, as declared in the tenant profile's
	// metric_templates (member + line). Index-free leaves are intentionally
	// present to prove they are ignored.
	templates := CountLeafTemplates([]string{
		"/Admin/ProdConsumedCount/{idx}/Unit",
		"/Admin/ProdProcessedCount/{idx}/Unit",
		"/Admin/ProdDefectiveCount/{idx}/Unit",
		"/Status/MachSpeed",           // index-free — must be dropped by the filter
		"/Status/Parameter30700",      // index-free
	})
	if len(templates) != 3 {
		t.Fatalf("CountLeafTemplates kept %d, want 3 ({idx}-bearing only)", len(templates))
	}

	cases := []struct {
		name      string
		fullName  string
		wantOK    bool
		wantTopic string
		wantIdx   int
		wantLeaf  string
	}{
		{
			name:      "member consumed count with foreign index",
			fullName:  "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit",
			wantOK:    true,
			wantTopic: "CPACK/SC/LINHAS/L5/BREYER",
			wantIdx:   61,
			wantLeaf:  "/Admin/ProdConsumedCount/{idx}/Unit",
		},
		{
			name:      "member processed count",
			fullName:  "CPACK/SC/LINHAS/L4/TEXA/Admin/ProdProcessedCount/65/Unit",
			wantOK:    true,
			wantTopic: "CPACK/SC/LINHAS/L4/TEXA",
			wantIdx:   65,
			wantLeaf:  "/Admin/ProdProcessedCount/{idx}/Unit",
		},
		{
			name:      "line count uses own id",
			fullName:  "CPACK/SC/LINHAS/L8/Admin/ProdConsumedCount/51/Unit",
			wantOK:    true,
			wantTopic: "CPACK/SC/LINHAS/L8",
			wantIdx:   51,
			wantLeaf:  "/Admin/ProdConsumedCount/{idx}/Unit",
		},
		{
			name:     "index-free tag is not count-bearing",
			fullName: "CPACK/SC/LINHAS/L5/BREYER/Status/MachSpeed",
			wantOK:   false,
		},
		{
			name:     "non-numeric index rejected",
			fullName: "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/ABC/Unit",
			wantOK:   false,
		},
		{
			name:     "wrong tail (not /Unit)",
			fullName: "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Value",
			wantOK:   false,
		},
		{
			name:     "unknown counter family not in templates",
			fullName: "CPACK/SC/LINHAS/L5/BREYER/Admin/ProdRejectCount/61/Unit",
			wantOK:   false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := ParseObservation(tc.fullName, templates)
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tc.wantOK)
			}
			if !tc.wantOK {
				return
			}
			if got.Topic != tc.wantTopic {
				t.Errorf("topic = %q, want %q", got.Topic, tc.wantTopic)
			}
			if got.CountIndex != tc.wantIdx {
				t.Errorf("count_index = %d, want %d", got.CountIndex, tc.wantIdx)
			}
			if got.MetricSuffix != tc.wantLeaf {
				t.Errorf("metric_suffix = %q, want %q", got.MetricSuffix, tc.wantLeaf)
			}
		})
	}
}

func TestParseObservation_NoTemplates(t *testing.T) {
	// No count templates ⇒ nothing is count-bearing (a tenant with no declared
	// count metrics records nothing).
	if _, ok := ParseObservation("CPACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit", nil); ok {
		t.Fatalf("expected no match with empty templates")
	}
}
