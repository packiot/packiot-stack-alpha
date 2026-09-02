package main

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/testutil"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/rawtag"
)

// testDeps returns pipelineDeps with throwaway (unregistered) metric vecs and an
// in-memory outbox — enough to build + drive a pipeline without a broker or DB.
func testDeps(t *testing.T) pipelineDeps {
	t.Helper()
	return pipelineDeps{
		logger:              slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		outboxPath:          ":memory:",
		dropped:             prometheus.NewCounterVec(prometheus.CounterOpts{Name: "t_dropped"}, []string{"reason"}),
		unmappedTags:        prometheus.NewCounterVec(prometheus.CounterOpts{Name: "t_unmapped"}, []string{"group", "segment", "reason"}),
		decomposed:          prometheus.NewCounterVec(prometheus.CounterOpts{Name: "t_decomposed"}, []string{"param_id"}),
		derivedSynth:        prometheus.NewCounter(prometheus.CounterOpts{Name: "t_derived"}),
		counterDerivedSynth: prometheus.NewCounter(prometheus.CounterOpts{Name: "t_counter_derived"}),
	}
}

// cfgFor builds an in-memory agent config for one tenant. prefix is the
// PackMLTopic; suffixes populate the raw_tag_map (all typed double).
func cfgFor(group, prefix string, suffixes ...string) *agentcfg.Config {
	cfg := &agentcfg.Config{
		Sparkplug: agentcfg.SparkplugCfg{
			GroupID:        group,
			EdgeNodeID:     "edge-" + group,
			PackMLTopic:    prefix,
			InternalBroker: "tcp://localhost:1883",
			UplinkBroker:   "tcp://localhost:1883",
		},
	}
	for _, s := range suffixes {
		cfg.RawTagMap = append(cfg.RawTagMap, agentcfg.TagMapEntry{MetricSuffix: s, Type: "double"})
	}
	return cfg
}

// birthByName reads a pipeline's current NBIRTH into name→alias, skipping the
// bdSeq bookkeeping metric. A rebirth freezes the full name↔alias table, so this
// is the authoritative view of what THIS tenant would publish.
func birthByName(t *testing.T, p *pipeline) map[string]uint64 {
	t.Helper()
	pl, err := p.pub.BuildNBIRTH(p.store.SnapshotForBirth())
	if err != nil {
		t.Fatalf("BuildNBIRTH(%s): %v", p.groupID, err)
	}
	out := make(map[string]uint64)
	for _, m := range pl.Metrics {
		if m.Name == nil || m.GetName() == "bdSeq" {
			continue
		}
		out[m.GetName()] = m.GetAlias()
	}
	return out
}

func feed(p *pipeline, suffixes ...string) (accepted, total int) {
	tags := make([]rawtag.RawTag, 0, len(suffixes))
	for i, s := range suffixes {
		tags = append(tags, rawtag.RawTag{Metric: s, Value: float64(i + 1), TsMillis: int64(i + 1)})
	}
	return p.ingest(tags)
}

// TestPipelineIsolation_AliasSpaceAndPrefix is the core multi-tenant invariant
// (requirement D + E.1): two pipelines with DISTINCT groups and an OVERLAPPING
// metric suffix resolve that suffix against their OWN map + prefix, and their
// alias spaces are independent.
//
// Tenant A maps {/Status/A1, /Status/Shared}; tenant B maps {/Status/Shared,
// /Status/Z9}. Aliases are assigned in suffix-sorted snapshot order, so:
//   - A: /Status/A1→1, /Status/Shared→2   (names under prefix "/A")
//   - B: /Status/Shared→1, /Status/Z9→2   (names under prefix "/B")
//
// The shared suffix therefore gets a DIFFERENT alias in each tenant (2 vs 1) and
// a DIFFERENT full name — proving the aliasmaps are not shared and each resolver
// applies its own tenant prefix.
func TestPipelineIsolation_AliasSpaceAndPrefix(t *testing.T) {
	pa, err := buildPipeline(cfgFor("GROUPA", "/A", "/Status/A1", "/Status/Shared"), testDeps(t))
	if err != nil {
		t.Fatalf("build A: %v", err)
	}
	defer pa.ob.Close()
	pb, err := buildPipeline(cfgFor("GROUPB", "/B", "/Status/Shared", "/Status/Z9"), testDeps(t))
	if err != nil {
		t.Fatalf("build B: %v", err)
	}
	defer pb.ob.Close()

	if acc, tot := feed(pa, "/Status/A1", "/Status/Shared"); acc != 2 || tot != 2 {
		t.Fatalf("A ingest: accepted=%d total=%d want 2/2", acc, tot)
	}
	if acc, tot := feed(pb, "/Status/Shared", "/Status/Z9"); acc != 2 || tot != 2 {
		t.Fatalf("B ingest: accepted=%d total=%d want 2/2", acc, tot)
	}

	a := birthByName(t, pa)
	b := birthByName(t, pb)

	// Each tenant publishes under its OWN prefix.
	if _, ok := a["/A/Status/Shared"]; !ok {
		t.Fatalf("A birth missing /A/Status/Shared; got %v", a)
	}
	if _, ok := b["/B/Status/Shared"]; !ok {
		t.Fatalf("B birth missing /B/Status/Shared; got %v", b)
	}
	if _, leaked := a["/B/Status/Shared"]; leaked {
		t.Fatalf("tenant A leaked tenant B's name; got %v", a)
	}

	// The SHARED suffix has independent aliases: 2 in A, 1 in B.
	if got := a["/A/Status/Shared"]; got != 2 {
		t.Fatalf("A alias for shared suffix = %d, want 2 (sorted after /Status/A1); got %v", got, a)
	}
	if got := b["/B/Status/Shared"]; got != 1 {
		t.Fatalf("B alias for shared suffix = %d, want 1 (sorted before /Status/Z9); got %v", got, b)
	}
}

// TestPipelineIsolation_StrictAllowlistPerTenant (requirement D): a suffix that
// is in tenant A's map but NOT tenant B's is dropped for B, independent of A.
func TestPipelineIsolation_StrictAllowlistPerTenant(t *testing.T) {
	pb, err := buildPipeline(cfgFor("GROUPB", "/B", "/Status/OnlyB"), testDeps(t))
	if err != nil {
		t.Fatalf("build B: %v", err)
	}
	defer pb.ob.Close()

	// "/Status/OnlyA" is unknown to B → dropped; "/Status/OnlyB" → accepted.
	acc, tot := feed(pb, "/Status/OnlyA", "/Status/OnlyB")
	if tot != 2 {
		t.Fatalf("total=%d want 2", tot)
	}
	if acc != 1 {
		t.Fatalf("accepted=%d want 1 (the foreign suffix must be dropped for B)", acc)
	}
	names := birthByName(t, pb)
	if len(names) != 1 {
		t.Fatalf("B birth should carry exactly its own 1 mapped tag; got %v", names)
	}
	if _, ok := names["/B/Status/OnlyB"]; !ok {
		t.Fatalf("B birth missing its own tag; got %v", names)
	}
}

// TestBuildTenantPipelines_LoadsDirectory (requirement A): every *.yaml becomes
// one pipeline keyed by group_id.
// testBuildDeps builds a buildDeps with fresh (unregistered) metric vecs for a
// buildTenantPipelines call. The counters are standalone, so several tests can
// each own one without a registry collision; tests that assert on the skip
// counter capture the returned deps and read deps.tenantLoadFailed.
func testBuildDeps() buildDeps {
	return buildDeps{
		logger:              slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		dropped:             prometheus.NewCounterVec(prometheus.CounterOpts{Name: "td_dropped"}, []string{"reason"}),
		unmappedTags:        prometheus.NewCounterVec(prometheus.CounterOpts{Name: "td_unmapped"}, []string{"group", "segment", "reason"}),
		decomposed:          prometheus.NewCounterVec(prometheus.CounterOpts{Name: "td_decomposed"}, []string{"param_id"}),
		derivedSynth:        prometheus.NewCounter(prometheus.CounterOpts{Name: "td_derived"}),
		counterDerivedSynth: prometheus.NewCounter(prometheus.CounterOpts{Name: "td_counter_derived"}),
		tenantLoadFailed:    prometheus.NewCounterVec(prometheus.CounterOpts{Name: "td_tenant_load_failed"}, []string{"file", "reason"}),
	}
}

// skipCount reads the skip counter value. Each of these tests skips exactly one
// file (one label set), so ToFloat64 is unambiguous.
func skipCount(t *testing.T, deps buildDeps) float64 {
	t.Helper()
	return testutil.ToFloat64(deps.tenantLoadFailed)
}

func TestBuildTenantPipelines_LoadsDirectory(t *testing.T) {
	dir := t.TempDir()
	writeCfg(t, dir, "alpha.yaml", "ALPHA", "/alpha")
	writeCfg(t, dir, "beta.yaml", "BETA", "/beta")
	writeCfg(t, dir, "notes.txt", "IGNORED", "/x") // non-yaml is ignored

	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))
	ps, err := buildTenantPipelines(dir, testBuildDeps())
	if err != nil {
		t.Fatalf("buildTenantPipelines: %v", err)
	}
	defer func() {
		for _, p := range ps {
			p.ob.Close()
		}
	}()
	if len(ps) != 2 {
		t.Fatalf("got %d pipelines, want 2 (alpha, beta; notes.txt ignored)", len(ps))
	}
	groups := map[string]bool{}
	for _, p := range ps {
		groups[p.groupID] = true
	}
	if !groups["ALPHA"] || !groups["BETA"] {
		t.Fatalf("missing expected groups; got %v", groups)
	}
	// Each pipeline got its OWN outbox file (single-drainer-per-outbox invariant).
	for _, g := range []string{"alpha", "beta"} {
		if _, err := os.Stat(filepath.Join(dir, "outbox", g+".db")); err != nil {
			t.Fatalf("expected per-tenant outbox %s.db: %v", g, err)
		}
	}
}

// TestBuildTenantPipelines_DuplicateGroupSkips (P0-1): a second config reusing an
// already-admitted group_id (case-insensitively) is SKIPPED-AND-ALARMED, not
// fatal — the first-seen tenant keeps serving, the duplicate is dropped + counted.
// Before ADR-0042 blast-radius isolation this returned an error → os.Exit(1) →
// the shared agent crash-looped and cpack lost ingest.
func TestBuildTenantPipelines_DuplicateGroupSkips(t *testing.T) {
	dir := t.TempDir()
	writeCfg(t, dir, "one.yaml", "CPACK", "/one")
	writeCfg(t, dir, "two.yaml", "cpack", "/two") // same group, different case
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))

	deps := testBuildDeps()
	ps, err := buildTenantPipelines(dir, deps)
	if err != nil {
		t.Fatalf("duplicate group_id must skip-and-alarm, not fail: %v", err)
	}
	defer func() {
		for _, p := range ps {
			p.ob.Close()
		}
	}()
	if len(ps) != 1 {
		t.Fatalf("got %d pipelines, want 1 (first-seen CPACK kept, dup skipped)", len(ps))
	}
	if ps[0].groupID != "CPACK" {
		t.Fatalf("kept pipeline group = %q, want first-seen CPACK", ps[0].groupID)
	}
	if n := skipCount(t, deps); n != 1 {
		t.Fatalf("tenant_load_failed = %v, want 1 (the skipped dup)", n)
	}
}

// TestBuildTenantPipelines_DuplicateEdgeNodeSkips (P0-1): two configs with
// distinct group_ids but the SAME edge_node_id — a shared edge_node_id yields
// identical uplink MQTT ClientIDs (broker evicts one session per connect). The
// duplicate is SKIPPED-AND-ALARMED; the first-seen tenant keeps serving.
func TestBuildTenantPipelines_DuplicateEdgeNodeSkips(t *testing.T) {
	dir := t.TempDir()
	writeCfgNode(t, dir, "a.yaml", "GROUPA", "/a", "shared-edge")
	writeCfgNode(t, dir, "b.yaml", "GROUPB", "/b", "SHARED-EDGE") // same node, different case
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))

	deps := testBuildDeps()
	ps, err := buildTenantPipelines(dir, deps)
	if err != nil {
		t.Fatalf("duplicate edge_node_id must skip-and-alarm, not fail: %v", err)
	}
	defer func() {
		for _, p := range ps {
			p.ob.Close()
		}
	}()
	if len(ps) != 1 {
		t.Fatalf("got %d pipelines, want 1 (first-seen kept, dup edge_node skipped)", len(ps))
	}
	if n := skipCount(t, deps); n != 1 {
		t.Fatalf("tenant_load_failed = %v, want 1 (the skipped dup edge_node)", n)
	}
}

// TestBuildTenantPipelines_BadConfigSkippedGoodSurvives (P0-1, THE guarantee): a
// malformed tenant file (missing group_id → agentcfg validate error, exactly the
// wizard-authored-descriptor footgun) is skipped, and a VALID co-tenant (cpack)
// in the same dir keeps serving. This is what makes apply-agent-config safe: one
// bad map can never take cpack ingest down.
func TestBuildTenantPipelines_BadConfigSkippedGoodSurvives(t *testing.T) {
	dir := t.TempDir()
	// Missing sparkplug.group_id → agentcfg.Load validate() error (mirrors a
	// wizard descriptor with no agent block → invalid generated agent.yaml).
	if err := os.WriteFile(filepath.Join(dir, "bad.yaml"),
		[]byte("sparkplug:\n  edge_node_id: e\n  internal_broker: tcp://x:1883\n  uplink_broker: tcp://x:1883\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	writeCfg(t, dir, "cpack.yaml", "CPACK", "/cpack") // the protected co-tenant
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))

	deps := testBuildDeps()
	ps, err := buildTenantPipelines(dir, deps)
	if err != nil {
		t.Fatalf("a bad file alongside a good one must NOT fail the agent: %v", err)
	}
	defer func() {
		for _, p := range ps {
			p.ob.Close()
		}
	}()
	if len(ps) != 1 || ps[0].groupID != "CPACK" {
		t.Fatalf("want exactly the CPACK pipeline surviving; got %d pipelines", len(ps))
	}
	if n := skipCount(t, deps); n != 1 {
		t.Fatalf("tenant_load_failed = %v, want 1 (the skipped bad.yaml)", n)
	}
}

// TestBuildTenantPipelines_AllBadOrEmptyFails: the infrastructure floor — a dir
// with NO loadable config (empty, or every file bad) still returns an error so
// main os.Exits loudly. This is a deploy-level fault, distinct from one bad file
// among good ones (which is isolated above).
func TestBuildTenantPipelines_AllBadOrEmptyFails(t *testing.T) {
	dir := t.TempDir() // empty
	t.Setenv("AGENT_OUTBOX_DIR", filepath.Join(dir, "outbox"))
	if _, err := buildTenantPipelines(dir, testBuildDeps()); err == nil {
		t.Fatal("expected empty tenants dir to fail startup, got nil")
	}
}

// TestSingleFilePipeline_Unchanged (requirement E.4 regression): the single-file
// buildPipeline path still resolves a mapped tag, drops an unmapped one, and
// mints an NBIRTH under the tenant prefix — the frozen prod behavior.
func TestSingleFilePipeline_Unchanged(t *testing.T) {
	p, err := buildPipeline(cfgFor("CPACK", "/CPACK", "/Status/MachSpeed"), testDeps(t))
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	defer p.ob.Close()

	acc, tot := feed(p, "/Status/MachSpeed", "/Status/Unmapped")
	if acc != 1 || tot != 2 {
		t.Fatalf("ingest accepted=%d total=%d want 1/2", acc, tot)
	}
	names := birthByName(t, p)
	if _, ok := names["/CPACK/Status/MachSpeed"]; !ok {
		t.Fatalf("birth missing mapped tag under prefix; got %v", names)
	}
	if _, ok := names["/CPACK/Status/Unmapped"]; ok {
		t.Fatalf("unmapped tag must not appear in birth; got %v", names)
	}
}

// TestSanitizeGroup guards the outbox-filename derivation against path escapes.
func TestSanitizeGroup(t *testing.T) {
	cases := map[string]string{
		"CPACK":      "cpack",
		"Group-1_x":  "group-1_x",
		"a/b":        "a_b",
		"../evil":    "___evil",
		"  Spaced  ": "spaced",
		"":           "tenant",
	}
	for in, want := range cases {
		if got := sanitizeGroup(in); got != want {
			t.Errorf("sanitizeGroup(%q)=%q want %q", in, got, want)
		}
	}
}

func writeCfg(t *testing.T, dir, file, group, prefix string) {
	t.Helper()
	writeCfgNode(t, dir, file, group, prefix, "edge-"+group)
}

func writeCfgNode(t *testing.T, dir, file, group, prefix, edgeNode string) {
	t.Helper()
	yaml := "sparkplug:\n" +
		"  group_id: " + group + "\n" +
		"  edge_node_id: " + edgeNode + "\n" +
		"  packml_topic: \"" + prefix + "\"\n" +
		"  internal_broker: tcp://localhost:1883\n" +
		"  uplink_broker: tcp://localhost:1883\n" +
		"raw_tag_map:\n" +
		"  - metric_suffix: /Status/MachSpeed\n" +
		"    type: double\n"
	if err := os.WriteFile(filepath.Join(dir, file), []byte(yaml), 0o644); err != nil {
		t.Fatal(err)
	}
}
