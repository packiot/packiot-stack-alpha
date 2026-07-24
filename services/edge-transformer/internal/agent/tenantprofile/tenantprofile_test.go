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
