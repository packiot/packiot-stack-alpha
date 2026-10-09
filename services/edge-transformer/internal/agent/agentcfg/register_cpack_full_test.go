package agentcfg

import (
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tenantprofile"
)

// cpackStagingRowsFull is the COMPLETE CPACK equipment set as staging ent-3
// packml_register holds it (SELECT-only read 2026-07-23: 62 rows, all active,
// id_equipment NOT NULL, one row per equipment). This is exactly what the
// register loader consumes live. Lines are tp_equipment=3 (id_unit NULL);
// members are tp_equipment=1. Topics are canonical (CPACK/…, already prefix-
// fixed from the tee's C-PACK/…).
func cpackStagingRowsFull() []RegisterRow {
	L := func(id int, topic string) RegisterRow { return RegisterRow{IDEquipment: id, PackMLTopic: topic, TPEquipment: 3} }
	M := func(id int, topic string) RegisterRow { return RegisterRow{IDEquipment: id, PackMLTopic: topic, TPEquipment: 1} }
	return []RegisterRow{
		// CELULA1 (single-machine cells: line + same-named member)
		L(83, "CPACK/SC/CELULA1/CER400"), M(88, "CPACK/SC/CELULA1/CER400/CER400"),
		L(84, "CPACK/SC/CELULA1/DUBUTI1"), M(89, "CPACK/SC/CELULA1/DUBUTI1/DUBUTI1"),
		L(81, "CPACK/SC/CELULA1/DUBUTI2"), M(86, "CPACK/SC/CELULA1/DUBUTI2/DUBUTI2"),
		L(82, "CPACK/SC/CELULA1/HOTMADAG"), M(87, "CPACK/SC/CELULA1/HOTMADAG/HOTMADAG"),
		L(85, "CPACK/SC/CELULA1/ISIMAT"), M(90, "CPACK/SC/CELULA1/ISIMAT/ISIMAT"),
		// CELULA2
		L(95, "CPACK/SC/CELULA2/BREYER1"), M(101, "CPACK/SC/CELULA2/BREYER1/BREYER1"),
		L(91, "CPACK/SC/CELULA2/BREYER2"), M(97, "CPACK/SC/CELULA2/BREYER2/BREYER2"),
		L(93, "CPACK/SC/CELULA2/POLYTYPE1"), M(99, "CPACK/SC/CELULA2/POLYTYPE1/POLYTYPE1"),
		L(96, "CPACK/SC/CELULA2/POLYTYPE2"), M(102, "CPACK/SC/CELULA2/POLYTYPE2/POLYTYPE2"),
		L(94, "CPACK/SC/CELULA2/PTH40-03"), M(100, "CPACK/SC/CELULA2/PTH40-03/PTH40-03"),
		L(92, "CPACK/SC/CELULA2/PTH80S"), M(98, "CPACK/SC/CELULA2/PTH80S/PTH80S"),
		// CELULA9
		L(103, "CPACK/SC/CELULA9/FLEXO"), M(104, "CPACK/SC/CELULA9/FLEXO/FLEXO"),
		// LINHAS L10
		L(52, "CPACK/SC/LINHAS/L10"), M(77, "CPACK/SC/LINHAS/L10/DXL"), M(78, "CPACK/SC/LINHAS/L10/PTH"),
		M(79, "CPACK/SC/LINHAS/L10/TCX"), M(80, "CPACK/SC/LINHAS/L10/TEXA"),
		// LINHAS L3
		L(48, "CPACK/SC/LINHAS/L3"), M(58, "CPACK/SC/LINHAS/L3/BREYER"), M(62, "CPACK/SC/LINHAS/L3/POLYTYPE"),
		M(61, "CPACK/SC/LINHAS/L3/PTH"), M(59, "CPACK/SC/LINHAS/L3/RMH"), M(60, "CPACK/SC/LINHAS/L3/TEXA"),
		// LINHAS L4
		L(49, "CPACK/SC/LINHAS/L4"), M(66, "CPACK/SC/LINHAS/L4/BREYER"), M(67, "CPACK/SC/LINHAS/L4/POLYTYPE"),
		M(64, "CPACK/SC/LINHAS/L4/PTH"), M(65, "CPACK/SC/LINHAS/L4/RMH"), M(63, "CPACK/SC/LINHAS/L4/TEXA"),
		// LINHAS L5
		L(47, "CPACK/SC/LINHAS/L5"), M(53, "CPACK/SC/LINHAS/L5/BREYER"), M(54, "CPACK/SC/LINHAS/L5/POLYTYPE"),
		M(55, "CPACK/SC/LINHAS/L5/PTH"), M(56, "CPACK/SC/LINHAS/L5/RMH"), M(57, "CPACK/SC/LINHAS/L5/TEXA"),
		// LINHAS L6
		L(50, "CPACK/SC/LINHAS/L6"), M(68, "CPACK/SC/LINHAS/L6/BREYER"), M(70, "CPACK/SC/LINHAS/L6/POLYTYPE"),
		M(72, "CPACK/SC/LINHAS/L6/PTH"), M(71, "CPACK/SC/LINHAS/L6/RMH"), M(69, "CPACK/SC/LINHAS/L6/TEXA"),
		// LINHAS L8
		L(51, "CPACK/SC/LINHAS/L8"), M(73, "CPACK/SC/LINHAS/L8/DXL"), M(74, "CPACK/SC/LINHAS/L8/PTH"),
		M(75, "CPACK/SC/LINHAS/L8/TCX"), M(76, "CPACK/SC/LINHAS/L8/TEXA"),
		// SLEEVE
		L(105, "CPACK/SC/SLEEVE/SLEEVE1"), M(107, "CPACK/SC/SLEEVE/SLEEVE1/SLEEVE1"),
		L(106, "CPACK/SC/SLEEVE/SLEEVE2"), M(108, "CPACK/SC/SLEEVE/SLEEVE2/SLEEVE2"),
	}
}

// TestBuildRawTagMap_CpackFullTopology is the task-#13 FULL-COVERAGE validation:
// cpack-full-profile.yaml + a register load of the complete staging ent-3
// equipment set must synthesize the whole plant (all 5 cells, both naming
// patterns) with no dropped equipment and no duplicate suffixes.
func TestBuildRawTagMap_CpackFullTopology(t *testing.T) {
	prof, err := tenantprofile.LoadProfile(repoFile(t, "docs/clients/cpack-full-profile.yaml"))
	if err != nil {
		t.Fatalf("load full profile: %v", err)
	}
	rows := cpackStagingRowsFull()
	gen, err := BuildRawTagMapFromRegister(prof, rows)
	if err != nil {
		t.Fatalf("build from register: %v", err)
	}

	// Count rows by class from the fixture.
	var lines, members int
	for _, r := range rows {
		if r.TPEquipment == 1 {
			members++
		} else {
			lines++
		}
	}
	if lines != 20 || members != 42 {
		t.Fatalf("fixture sanity: got %d lines / %d members, want 20 / 42", lines, members)
	}
	// line template = 6 leaves, member template = 5 leaves.
	wantEntries := lines*6 + members*5 // 120 + 210 = 330
	if len(gen) != wantEntries {
		t.Errorf("entry count: got %d, want %d (20 lines*6 + 42 members*5)", len(gen), wantEntries)
	}

	// No duplicate suffixes across the whole plant.
	seen := map[string]bool{}
	for _, e := range gen {
		if seen[e.MetricSuffix] {
			t.Errorf("duplicate suffix: %q", e.MetricSuffix)
		}
		seen[e.MetricSuffix] = true
	}

	// Every one of the 62 equipment contributed at least its StateCurrent tag,
	// i.e. no cell was silently skipped by the prefix.
	for _, r := range rows {
		local := strings.TrimPrefix(r.PackMLTopic, "CPACK/SC")
		if !seen[local+"/Status/StateCurrent"] {
			t.Errorf("equipment not covered by loader: %q (missing %q)", r.PackMLTopic, local+"/Status/StateCurrent")
		}
	}

	// Spot-check the load-bearing count-index overrides across every quirk class.
	cases := []struct{ name, suffix string }{
		{"L3/PTH prod-id idx 81", "/LINHAS/L3/PTH/Admin/ProdProcessedCount/81/Unit"},
		{"L4/BREYER small-series idx 6", "/LINHAS/L4/BREYER/Admin/ProdConsumedCount/6/Unit"},
		{"L5/BREYER prod-id idx 61", "/LINHAS/L5/BREYER/Admin/ProdConsumedCount/61/Unit"},
		{"L6/TEXA prod-id idx 92", "/LINHAS/L6/TEXA/Admin/ProdProcessedCount/92/Unit"},
		{"L8/DXL inferred idx 219", "/LINHAS/L8/DXL/Admin/ProdConsumedCount/219/Unit"},
		{"CELULA2/BREYER1 anomaly idx 26", "/CELULA2/BREYER1/BREYER1/Admin/ProdConsumedCount/26/Unit"},
		{"CELULA2/POLYTYPE2 anomaly idx 29", "/CELULA2/POLYTYPE2/POLYTYPE2/Admin/ProdConsumedCount/29/Unit"},
		{"CELULA1/CER400 idx 107", "/CELULA1/CER400/CER400/Admin/ProdProcessedCount/107/Unit"},
		{"SLEEVE1 inferred idx 763", "/SLEEVE/SLEEVE1/SLEEVE1/Admin/ProdConsumedCount/763/Unit"},
	}
	for _, c := range cases {
		if !seen[c.suffix] {
			t.Errorf("%s: expected suffix %q not synthesized", c.name, c.suffix)
		}
	}

	// Lines carry Parameter30700 (line-machines CSV); members must not.
	if !seen["/LINHAS/L8/Status/Parameter30700"] {
		t.Errorf("line L8 missing Parameter30700")
	}
	if seen["/LINHAS/L8/DXL/Status/Parameter30700"] {
		t.Errorf("member L8/DXL must not carry Parameter30700")
	}
	// Lines carry BARE counts (no /idx/Unit) — the real prod line shape (#590).
	if !seen["/LINHAS/L8/Admin/ProdProcessedCount"] {
		t.Errorf("line L8 missing bare ProdProcessedCount")
	}

	// The generated map must survive full agentcfg validation.
	cfg := &Config{
		Sparkplug: SparkplugCfg{
			GroupID:        "CPACK",
			EdgeNodeID:     "cpack-tee",
			PackMLTopic:    "CPACK/SC",
			InternalBroker: "tcp://mosquitto:1883",
			UplinkBroker:   "tcp://mosquitto:1883",
		},
		RawTagMap: gen,
	}
	if err := cfg.validate(); err != nil {
		t.Errorf("generated full raw_tag_map fails agentcfg validation: %v", err)
	}
}

// TestIncoplastProfile_LoadsAndSynthesizes proves the Incoplast DRAFT profile
// parses + validates and that its count-index overrides (== id_unit) are applied.
// Rows are the real prod ent-33 line+member topology, canonicalised to the
// tenant prefix (the shape the loader sees post-fixup).
func TestIncoplastProfile_LoadsAndSynthesizes(t *testing.T) {
	prof, err := tenantprofile.LoadProfile(repoFile(t, "docs/clients/incoplast-profile.yaml"))
	if err != nil {
		t.Fatalf("load incoplast profile: %v", err)
	}
	L := func(id int, topic string) RegisterRow { return RegisterRow{IDEquipment: id, PackMLTopic: topic, TPEquipment: 3} }
	M := func(id int, topic string) RegisterRow { return RegisterRow{IDEquipment: id, PackMLTopic: topic, TPEquipment: 1} }
	rows := []RegisterRow{
		L(214, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/MIRAFLEX_28"), M(215, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/MIRAFLEX_28/MIRAFLEX_28"),
		L(216, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_11"), M(217, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_11/NOVOFLEX_11"),
		L(17, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15"), M(18, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/NOVOFLEX_15/NOVOFLEX_15"),
		L(212, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/PRIMAFLEX_9"), M(213, "INCOPLAST/SAO_LUDGERO/IMPRESSAO/PRIMAFLEX_9/PRIMAFLEX_9"),
	}
	gen, err := BuildRawTagMapFromRegister(prof, rows)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	seen := map[string]bool{}
	for _, e := range gen {
		seen[e.MetricSuffix] = true
	}
	// Count index tracks id_unit (1/2/3/4), NOT id_equipment (18/217/213/215).
	want := []string{
		"/NOVOFLEX_15/NOVOFLEX_15/Admin/ProdConsumedCount/1/Unit",
		"/NOVOFLEX_11/NOVOFLEX_11/Admin/ProdConsumedCount/2/Unit",
		"/PRIMAFLEX_9/PRIMAFLEX_9/Admin/ProdConsumedCount/3/Unit",
		"/MIRAFLEX_28/MIRAFLEX_28/Admin/ProdConsumedCount/4/Unit",
	}
	for _, s := range want {
		if !seen[s] {
			t.Errorf("expected id_unit-indexed suffix %q not synthesized", s)
		}
	}
	// The default (id_equipment) would have produced /18/Unit — assert it did NOT.
	if seen["/NOVOFLEX_15/NOVOFLEX_15/Admin/ProdConsumedCount/18/Unit"] {
		t.Errorf("count index fell back to id_equipment (18) instead of id_unit override (1)")
	}
}

// TestBuildRawTagMap_LinhasOnlyProfileSkipsOtherCells documents WHY the widened
// prefix is necessary: the LINHAS-only profile (cpack-profile.yaml, prefix
// CPACK/SC/LINHAS) drops every CELULA/SLEEVE equipment because they fall outside
// its prefix. This is the coverage gap this profile closes.
func TestBuildRawTagMap_LinhasOnlyProfileSkipsOtherCells(t *testing.T) {
	prof, err := tenantprofile.LoadProfile(repoFile(t, "docs/clients/cpack-profile.yaml"))
	if err != nil {
		t.Fatalf("load LINHAS profile: %v", err)
	}
	gen, err := BuildRawTagMapFromRegister(prof, cpackStagingRowsFull())
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	for _, e := range gen {
		if strings.Contains(e.MetricSuffix, "CELULA") || strings.Contains(e.MetricSuffix, "SLEEVE") {
			t.Fatalf("LINHAS-only profile unexpectedly emitted non-LINHAS suffix %q", e.MetricSuffix)
		}
		if !strings.HasPrefix(e.MetricSuffix, "/L") {
			t.Fatalf("LINHAS-only profile emitted unexpected suffix %q", e.MetricSuffix)
		}
	}
}
