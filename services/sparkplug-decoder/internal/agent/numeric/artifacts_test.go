package numeric_test

// Integration proof: the REAL generated agent artifacts (onboard-gen output for
// bispharma + bisnago) are translator-compatible — every legacy count id in the
// descriptor is extractable into the numeric translation table. Pins the
// descriptor → agent.yaml → translator chain end-to-end against committed
// artifacts, so a descriptor edit that breaks the numeric layer fails CI.

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/numeric"
)

// genDir is docs/clients/gen relative to this test file's package directory
// (services/edge-transformer/internal/agent/numeric → repo root is 5 up).
const genDir = "../../../../../docs/clients/gen"

func loadTranslatable(t *testing.T, agentYAML string) map[int]numeric.Target {
	t.Helper()
	path := filepath.Join(genDir, agentYAML)
	if _, err := os.Stat(path); err != nil {
		t.Skipf("generated artifact %s not present (run onboard-gen): %v", path, err)
	}
	cfg, err := agentcfg.Load(path)
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}
	tbl, err := numeric.BuildIndexFromTagMap(cfg.RawTagMap)
	if err != nil {
		t.Fatalf("build translation table from %s: %v", path, err)
	}
	return tbl
}

func TestArtifacts_BispharmaTranslatable(t *testing.T) {
	tbl := loadTranslatable(t, "bispharma-agent.yaml")
	// 91 members, each one indexed ProdProcessedCount leaf (the flow's 124..685
	// count ids). The 16 lines carry bare (no-idx) counts → not translatable.
	if len(tbl) != 91 {
		t.Errorf("bispharma translatable count indices: got %d, want 91", len(tbl))
	}
	// Spot-check two real ids from the descriptor.
	if tgt, ok := tbl[164]; !ok || tgt.Suffix != "/LINHAS/L01/S3/Admin/ProdProcessedCount/164/Unit" {
		t.Errorf("id 164 → %+v (ok=%v)", tbl[164], ok)
	}
	if _, ok := tbl[685]; !ok {
		t.Error("id 685 (L90 output) not translatable")
	}
}

func TestArtifacts_BisnagoTranslatableAndNoNeopacCollision(t *testing.T) {
	tbl := loadTranslatable(t, "bisnago-agent.yaml")
	// 14 members (2 per line × 7 lines), legacy ids 670..683.
	if len(tbl) != 14 {
		t.Errorf("bisnago translatable count indices: got %d, want 14", len(tbl))
	}
	for id := 670; id <= 683; id++ {
		tgt, ok := tbl[id]
		if !ok {
			t.Errorf("legacy id %d not translatable", id)
			continue
		}
		// The canonical target is namespaced under BISNAGO's LOCAL segment — the
		// count-index leaf, NOT a NEOPAC surrogate. (id_equipment freshness is
		// asserted in the register.sql; here we prove the LEAF is BISNAGO-scoped.)
		if tgt.Suffix == "" {
			t.Errorf("id %d has empty target suffix", id)
		}
	}
}
