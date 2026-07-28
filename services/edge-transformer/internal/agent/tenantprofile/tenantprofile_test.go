package tenantprofile

import "testing"

func cpackProfile() *Profile {
	return &Profile{
		Tenant:       "CPACK",
		EnterpriseID: 3,
		TenantPrefix: "CPACK/SC/LINHAS",
		PrefixFixups: []Rewrite{{From: "C-PACK/", To: "CPACK/"}},
		MetricAliases: []Rewrite{
			{From: "Status/CurMachSpeed", To: "Status/MachSpeed"},
		},
		ParameterAliases: []ParameterAlias{
			{From: "Status/Parameter", To: "Status/Parameter30700", AppliesTo: ClassLine},
		},
		ParameterDecomposition: ParameterDecomposition{
			SourceLeaf: "/Status/Parameter",
			Params: []DecomposedParam{
				{ID: 30700, Leaf: "/Status/Parameter30700", AppliesTo: ClassLine},
				{ID: 30701, Leaf: "/Status/Parameter30701"},
				{ID: 30758, Leaf: "/Status/Parameter30758"},
			},
		},
		CountIndex: CountIndexRule{
			Mode:      "equipment_id",
			Overrides: map[string]int{"/L5/BREYER": 61},
		},
		MetricTemplates: MetricTemplates{
			Line: []TemplateEntry{
				{Leaf: "/Admin/ProdConsumedCount/{idx}/Unit", Type: "double"},
				{Leaf: "/Status/MachSpeed", Type: "double"},
				{Leaf: "/Status/Parameter30700", Type: "string"},
			},
			Member: []TemplateEntry{
				{Leaf: "/Admin/ProdConsumedCount/{idx}/Unit", Type: "double"},
				{Leaf: "/Status/MachSpeed", Type: "double"},
			},
		},
	}
}

func TestValidate(t *testing.T) {
	if err := cpackProfile().Validate(); err != nil {
		t.Fatalf("valid profile rejected: %v", err)
	}
	// Missing prefix.
	p := cpackProfile()
	p.TenantPrefix = ""
	if err := p.Validate(); err == nil {
		t.Error("empty tenant_prefix must be rejected")
	}
	// Bad count-index mode.
	p = cpackProfile()
	p.CountIndex.Mode = "bogus"
	if err := p.Validate(); err == nil {
		t.Error("bad count_index.mode must be rejected")
	}
	// Bad template type.
	p = cpackProfile()
	p.MetricTemplates.Line[0].Type = "int128"
	if err := p.Validate(); err == nil {
		t.Error("invalid template type must be rejected")
	}
}

func TestClassOf(t *testing.T) {
	for tp, want := range map[int]EquipClass{1: ClassMember, 2: ClassLine, 3: ClassLine} {
		if got := ClassOf(tp); got != want {
			t.Errorf("ClassOf(%d)=%q want %q", tp, got, want)
		}
	}
}

func TestLocalSegment(t *testing.T) {
	p := cpackProfile()
	cases := []struct {
		topic  string
		want   string
		wantOK bool
	}{
		{"CPACK/SC/LINHAS/L5/BREYER", "/L5/BREYER", true},
		{"CPACK/SC/LINHAS", "", true},                       // tenant root
		{"OTHER/SC/LINHAS/L1", "OTHER/SC/LINHAS/L1", false}, // cross-tenant
	}
	for _, c := range cases {
		got, ok := p.LocalSegment(c.topic)
		if got != c.want || ok != c.wantOK {
			t.Errorf("LocalSegment(%q)=(%q,%v) want (%q,%v)", c.topic, got, ok, c.want, c.wantOK)
		}
	}
}

func TestResolveCountIndex(t *testing.T) {
	p := cpackProfile()
	// Override wins over id_equipment.
	if idx, _ := p.ResolveCountIndex("/L5/BREYER", 53); idx != 61 {
		t.Errorf("override: got %d want 61", idx)
	}
	// Default = id_equipment.
	if idx, _ := p.ResolveCountIndex("/L4/TEXA", 63); idx != 63 {
		t.Errorf("default: got %d want 63", idx)
	}
	// explicit mode without override errors.
	p.CountIndex.Mode = "explicit"
	if _, err := p.ResolveCountIndex("/L9/NEW", 99); err == nil {
		t.Error("explicit mode with no override must error")
	}
}

func TestSynthesizeEquipment(t *testing.T) {
	p := cpackProfile()
	// A member with an override: count index 61, no Parameter30700.
	got, err := p.SynthesizeEquipment("/L5/BREYER", ClassMember, 53)
	if err != nil {
		t.Fatal(err)
	}
	byS := map[string]string{}
	for _, m := range got {
		byS[m.Suffix] = m.Type
	}
	if byS["/L5/BREYER/Admin/ProdConsumedCount/61/Unit"] != "double" {
		t.Errorf("member count suffix wrong: %v", byS)
	}
	if _, has := byS["/L5/BREYER/Status/Parameter30700"]; has {
		t.Error("member must not get line-only Parameter30700")
	}
	// A line uses its own id and DOES get Parameter30700.
	got, _ = p.SynthesizeEquipment("/L8", ClassLine, 51)
	byS = map[string]string{}
	for _, m := range got {
		byS[m.Suffix] = m.Type
	}
	if byS["/L8/Admin/ProdConsumedCount/51/Unit"] != "double" {
		t.Errorf("line count suffix wrong: %v", byS)
	}
	if byS["/L8/Status/Parameter30700"] != "string" {
		t.Error("line must get Parameter30700")
	}
}

func TestDecomposeParameterSuffix(t *testing.T) {
	p := cpackProfile()
	cases := []struct {
		name    string
		suffix  string
		paramID int
		want    string
		wantOK  bool
	}{
		// The load-bearing case: a LINE's bare Parameter + id 30700 becomes the
		// canonical numbered leaf the Calc's seedFromMetric + Phase-9 read.
		{"line 30700 CSV", "/L5/Status/Parameter", 30700, "/L5/Status/Parameter30700", true},
		{"line 30701 ideal speed", "/L5/Status/Parameter", 30701, "/L5/Status/Parameter30701", true},
		{"line 30758 event trigger", "/L8/Status/Parameter", 30758, "/L8/Status/Parameter30758", true},
		// Undeclared id → left bare (dropped downstream, never misrouted).
		{"undeclared PO-control 30800", "/L5/Status/Parameter", 30800, "/L5/Status/Parameter", false},
		// A non-Parameter suffix is never touched even with an id present.
		{"non-parameter leaf", "/L5/Status/MachSpeed", 30700, "/L5/Status/MachSpeed", false},
		// No id on the tag → not a decomposable Parameter write.
		{"no param id", "/L5/Status/Parameter", 0, "/L5/Status/Parameter", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := p.DecomposeParameterSuffix(c.suffix, c.paramID)
			if got != c.want || ok != c.wantOK {
				t.Errorf("Decompose(%q, %d) = (%q, %v), want (%q, %v)",
					c.suffix, c.paramID, got, ok, c.want, c.wantOK)
			}
		})
	}
}

// TestDecompose_ProvesPhase9Input pins the exact property Phase-9 depends on:
// the decomposed full metric name ends with "/Status/Parameter30700", the
// literal suffix cmd/edge-transformer seedFromMetric HasSuffix-matches to seed
// the line-machines CSV that calc_production_counters.runPhase9LineAggregation
// reads. Before decomposition the bare name matches none of the seeds.
func TestDecompose_ProvesPhase9Input(t *testing.T) {
	p := cpackProfile()
	bareSuffix := "/L5/Status/Parameter"
	bareFull := p.TenantPrefix + bareSuffix
	if got := hasParam30700(bareFull); got {
		t.Fatalf("bare Parameter should NOT match the Calc's Parameter30700 seed: %q", bareFull)
	}
	decSuffix, ok := p.DecomposeParameterSuffix(bareSuffix, 30700)
	if !ok {
		t.Fatal("expected 30700 to decompose")
	}
	decFull := p.TenantPrefix + decSuffix
	if !hasParam30700(decFull) {
		t.Fatalf("decomposed name must match the Calc's Parameter30700 seed, got %q", decFull)
	}
}

// hasParam30700 mirrors the exact check in cmd/edge-transformer seedFromMetric
// (HasSuffix(name, "/Status/Parameter30700")) and line_aggregation's key build.
func hasParam30700(fullName string) bool {
	const suf = "/Status/Parameter30700"
	return len(fullName) >= len(suf) && fullName[len(fullName)-len(suf):] == suf
}

func TestValidate_ParameterDecomposition(t *testing.T) {
	base := func() *Profile { return cpackProfile() }

	if err := base().Validate(); err != nil {
		t.Fatalf("valid cpack profile rejected: %v", err)
	}

	p := base()
	p.ParameterDecomposition.Params = nil
	if err := p.Validate(); err == nil {
		t.Error("source_leaf set with empty params should be rejected")
	}

	p = base()
	p.ParameterDecomposition.Params = []DecomposedParam{{ID: 30700, Leaf: ""}}
	if err := p.Validate(); err == nil {
		t.Error("empty leaf should be rejected")
	}

	p = base()
	p.ParameterDecomposition.Params = []DecomposedParam{{ID: 0, Leaf: "/x"}}
	if err := p.Validate(); err == nil {
		t.Error("id <= 0 should be rejected")
	}

	p = base()
	p.ParameterDecomposition.Params = []DecomposedParam{
		{ID: 30700, Leaf: "/a"}, {ID: 30700, Leaf: "/b"},
	}
	if err := p.Validate(); err == nil {
		t.Error("duplicate id should be rejected")
	}

	p = base()
	p.ParameterDecomposition.Params = []DecomposedParam{{ID: 30700, Leaf: "/x", AppliesTo: "bogus"}}
	if err := p.Validate(); err == nil {
		t.Error("invalid applies_to should be rejected")
	}

	// Absent rule (SourceLeaf empty) is valid.
	p = base()
	p.ParameterDecomposition = ParameterDecomposition{}
	if err := p.Validate(); err != nil {
		t.Errorf("absent parameter_decomposition should be valid: %v", err)
	}
}
