package main

import (
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/rawtag"
	"github.com/packiot/packiot-stack-alpha/services/edge-transformer/internal/agent/tagstore"
)

// testResolver builds a resolver from a minimal in-memory raw_tag_map so the
// ingest loop can be exercised without loading YAML from disk.
func testResolver(t *testing.T, suffixes ...string) *resolver {
	t.Helper()
	cfg := &agentcfg.Config{
		Sparkplug: agentcfg.SparkplugCfg{PackMLTopic: "spBv1.0/CPACK/DDATA/L8"},
	}
	for _, s := range suffixes {
		cfg.RawTagMap = append(cfg.RawTagMap, agentcfg.TagMapEntry{MetricSuffix: s, Type: "double"})
	}
	return newResolver(cfg)
}

// TestIngestTags_UnmappedNotApplied is the P0 behavioural guarantee at the
// ingest boundary: an unmapped suffix is REPORTED (onUnmapped) and NOT applied
// to the store (so it can never be published), while a mapped suffix is applied
// and left completely unaffected by the new observation path.
func TestIngestTags_UnmappedNotApplied(t *testing.T) {
	r := testResolver(t, "/L8/Status/MachSpeed")
	store := tagstore.New()

	var reported []string
	onUnmapped := func(suffix string) { reported = append(reported, suffix) }

	tags := []rawtag.RawTag{
		{Metric: "/L8/Status/MachSpeed", Value: 118.4, Quality: true},                    // mapped
		{Metric: "/L8/Admin/ProdProcessedCount/99/Unit", Value: 40321.0, Quality: true}, // unmapped
	}
	accepted, total := ingestTags(tags, r, store, onUnmapped)

	if accepted != 1 || total != 2 {
		t.Fatalf("counts: got accepted=%d total=%d, want 1/2", accepted, total)
	}
	// Exactly the unmapped suffix was reported.
	if len(reported) != 1 || reported[0] != "/L8/Admin/ProdProcessedCount/99/Unit" {
		t.Fatalf("reported: got %v, want the one unmapped suffix", reported)
	}
	// The store carries ONLY the mapped tag — the unmapped one never entered
	// the publish path.
	snap := store.Snapshot()
	if len(snap) != 1 || snap[0].Metric != "/L8/Status/MachSpeed" {
		t.Fatalf("store snapshot: got %+v, want only the mapped tag", snap)
	}
}

// TestIngestTags_AllMapped_NoReports confirms the mapped-only path is unchanged:
// no unmapped reports fire and every tag is applied.
func TestIngestTags_AllMapped_NoReports(t *testing.T) {
	r := testResolver(t, "/L8/Status/MachSpeed", "/L8/Status/StateCurrent")
	store := tagstore.New()

	var reports int
	tags := []rawtag.RawTag{
		{Metric: "/L8/Status/MachSpeed", Value: 100.0, Quality: true},
		{Metric: "/L8/Status/StateCurrent", Value: 6.0, Quality: true},
	}
	accepted, total := ingestTags(tags, r, store, func(string) { reports++ })

	if accepted != 2 || total != 2 || reports != 0 {
		t.Fatalf("all-mapped: got accepted=%d total=%d reports=%d, want 2/2/0", accepted, total, reports)
	}
}
