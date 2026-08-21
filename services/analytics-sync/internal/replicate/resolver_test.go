package replicate

import "testing"

// The legacy/staging topics differ only in the enterprise-name segment
// (C-PACK vs CPACK); everything after the first slash is the stable natural
// key. These are real rows sampled from both prod DBs.
func TestNormalizeBaseTopic(t *testing.T) {
	cases := map[string]string{
		"C-PACK/SC/LINHAS/L5/BREYER": "SC/LINHAS/L5/BREYER",
		"CPACK/SC/LINHAS/L5/BREYER":  "SC/LINHAS/L5/BREYER",
		"C-PACK/SC/LINHAS/L5":        "SC/LINHAS/L5",
		"CPACK/SC/LINHAS/L5":         "SC/LINHAS/L5",
		"noslash":                    "",
	}
	for in, want := range cases {
		if got := normalizeBaseTopic(in); got != want {
			t.Errorf("normalizeBaseTopic(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBaseTopicByEquipPicksCleanBase(t *testing.T) {
	// id 61 (L5-BREYER) has four topics in prod; only the bare one is the base.
	rows := []equipTopic{
		{61, "C-PACK/SC/LINHAS/L5/BREYER/Admin/ProdDefectiveCount/61/Unit"},
		{61, "C-PACK/SC/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit"},
		{61, "C-PACK/SC/LINHAS/L5/BREYER"},
		{61, "C-PACK/SC/LINHAS/L5/BREYER/Admin/ProdProcessedCount/61/Unit"},
		// id 91 (L6-BREYER) also carries a /Status/CurMachSpeed leaf.
		{91, "C-PACK/SC/LINHAS/L6/BREYER"},
		{91, "C-PACK/SC/LINHAS/L6/BREYER/Status/CurMachSpeed"},
	}
	got := baseTopicByEquip(rows)
	if got[61] != "SC/LINHAS/L5/BREYER" {
		t.Errorf("id 61 base = %q, want SC/LINHAS/L5/BREYER", got[61])
	}
	if got[91] != "SC/LINHAS/L6/BREYER" {
		t.Errorf("id 91 base = %q, want SC/LINHAS/L6/BREYER", got[91])
	}
}

// End-to-end legacy->staging join proof (real ids from both DBs): equipment
// names are NOT unique (BREYER repeats across L3/L4/L5/L6) so only the topic
// path resolves correctly.
func TestLegacyStagingEquipmentJoin(t *testing.T) {
	legacy := baseTopicByEquip([]equipTopic{
		{60, "C-PACK/SC/LINHAS/L5"},
		{61, "C-PACK/SC/LINHAS/L5/BREYER"},
		{88, "C-PACK/SC/LINHAS/L4/BREYER"},
		{556, "C-PACK/SC/CELULA9/FLEXO"},
		{822, "C-PACK/SC/SLEEVE/SLEEVE2"},
	})
	staging := baseTopicByEquip([]equipTopic{
		{47, "CPACK/SC/LINHAS/L5"},
		{53, "CPACK/SC/LINHAS/L5/BREYER"},
		{66, "CPACK/SC/LINHAS/L4/BREYER"},
		{103, "CPACK/SC/CELULA9/FLEXO"},
		{106, "CPACK/SC/SLEEVE/SLEEVE2"},
	})
	byNorm := map[string]int{}
	for id, n := range staging {
		byNorm[n] = id
	}
	want := map[int]int{60: 47, 61: 53, 88: 66, 556: 103, 822: 106}
	for legID, norm := range legacy {
		if byNorm[norm] != want[legID] {
			t.Errorf("legacy %d (%s) -> staging %d, want %d", legID, norm, byNorm[norm], want[legID])
		}
	}
}
