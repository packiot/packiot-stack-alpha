package clientdescriptor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/agentcfg"
	"github.com/packiot/packiot-stack-alpha/services/sparkplug-decoder/internal/agent/tenantprofile"
)

// repoFile walks up from the test's working directory until it finds the given
// repo-relative path (mirrors agentcfg.repoFile so the test is insensitive to
// how deep the package sits).
func repoFile(t *testing.T, rel string) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		cand := filepath.Join(dir, rel)
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	t.Fatalf("could not locate %q walking up from test dir", rel)
	return ""
}

func loadCPACK(t *testing.T) *Descriptor {
	t.Helper()
	d, err := Load(repoFile(t, "docs/clients/cpack.descriptor.yaml"))
	if err != nil {
		t.Fatalf("load cpack descriptor: %v", err)
	}
	return d
}

// TestGenerateProfile_MatchesHandBuiltCPACK is the ADR-0045 P1 ACCEPTANCE GATE
// (the #593-equivalence pattern): the profile GENERATED from cpack.descriptor.yaml
// must be byte-for-byte identical — field for field, override for override — to
// the profile a human hand-built at docs/clients/cpack-full-profile.yaml (#601).
// If they diverge, the descriptor is not a faithful SSoT for that profile and the
// "generate, never hand-edit" promise is broken.
func TestGenerateProfile_MatchesHandBuiltCPACK(t *testing.T) {
	d := loadCPACK(t)

	got, err := d.GenerateProfile()
	if err != nil {
		t.Fatalf("GenerateProfile: %v", err)
	}
	want, err := tenantprofile.LoadProfile(repoFile(t, "docs/clients/cpack-full-profile.yaml"))
	if err != nil {
		t.Fatalf("load hand-built profile: %v", err)
	}

	if !reflect.DeepEqual(got, want) {
		// Narrow the diff for the reader before dumping the whole struct.
		if got.TenantPrefix != want.TenantPrefix {
			t.Errorf("tenant_prefix: got %q want %q", got.TenantPrefix, want.TenantPrefix)
		}
		if !reflect.DeepEqual(got.CountIndex, want.CountIndex) {
			for k, wv := range want.CountIndex.Overrides {
				if gv, ok := got.CountIndex.Overrides[k]; !ok {
					t.Errorf("override %q missing in generated", k)
				} else if gv != wv {
					t.Errorf("override %q: got %d want %d", k, gv, wv)
				}
			}
			for k := range got.CountIndex.Overrides {
				if _, ok := want.CountIndex.Overrides[k]; !ok {
					t.Errorf("override %q extra in generated", k)
				}
			}
		}
		if !reflect.DeepEqual(got.MetricTemplates, want.MetricTemplates) {
			t.Errorf("metric_templates differ:\n got %+v\nwant %+v", got.MetricTemplates, want.MetricTemplates)
		}
		t.Fatalf("generated profile != hand-built cpack-full-profile.yaml")
	}
}

// TestGenerateProfile_OverrideCount pins the coverage number the equivalence
// depends on: CPACK has 42 members (tp=1), each contributing exactly one
// count-index override. A drift here (a member gaining/losing its index) would
// silently move the parity target.
func TestGenerateProfile_OverrideCount(t *testing.T) {
	d := loadCPACK(t)
	p, err := d.GenerateProfile()
	if err != nil {
		t.Fatal(err)
	}
	members := 0
	for _, e := range d.Equipment {
		if e.TPEquipment == 1 {
			members++
		}
	}
	if members != 42 {
		t.Errorf("expected 42 CPACK members, got %d", members)
	}
	if len(p.CountIndex.Overrides) != members {
		t.Errorf("overrides=%d, want one per member (%d)", len(p.CountIndex.Overrides), members)
	}
}

// TestGenerateAgentConfig_ValidAndComplete proves the generated agent descriptor
// (artifact 3) round-trips through the REAL agentcfg validator — the same code
// that guards a live agent — and that its raw_tag_map covers every equipment.
func TestGenerateAgentConfig_ValidAndComplete(t *testing.T) {
	d := loadCPACK(t)
	cfg, err := d.GenerateAgentConfig()
	if err != nil {
		t.Fatalf("GenerateAgentConfig: %v", err)
	}
	if cfg.Sparkplug.GroupID != "CPACK" || cfg.Sparkplug.PackMLTopic != "CPACK/SC" {
		t.Errorf("sparkplug identity wrong: %+v", cfg.Sparkplug)
	}
	// Round-trip through agentcfg.Load (marshals to a temp file, then the real
	// validator + defaulting runs) — the strongest "is this a valid agent?" check.
	art, err := d.Generate(GenerateOptions{})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	tmp := filepath.Join(t.TempDir(), "agent.yaml")
	if err := os.WriteFile(tmp, art.AgentYAML, 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := agentcfg.Load(tmp)
	if err != nil {
		t.Fatalf("generated agent.yaml rejected by agentcfg.Load: %v", err)
	}
	// Every line gets 6 metrics (incl. Parameter30700), every member 5. Assert the
	// map is non-trivial and each equipment's count leaf resolved to its captured
	// index (spot-check L5/BREYER → 61 and L6/BREYER → 91, which is NOT its id 68).
	tm := loaded.TagMap()
	for _, want := range []string{
		"/LINHAS/L5/BREYER/Admin/ProdProcessedCount/61/Unit",
		"/LINHAS/L6/BREYER/Admin/ProdProcessedCount/91/Unit",
		"/LINHAS/L5/Status/Parameter30700",
	} {
		if _, ok := tm[want]; !ok {
			t.Errorf("agent raw_tag_map missing expected suffix %q", want)
		}
	}
	// A member must NOT get the line-only Parameter30700.
	if _, ok := tm["/LINHAS/L5/BREYER/Status/Parameter30700"]; ok {
		t.Error("member wrongly got line-only Parameter30700")
	}
}

// TestGenerateRegisterSQL checks the register artifact is well-formed, idempotent,
// and binds each topic to its id_equipment/id_unit as the descriptor declares.
func TestGenerateRegisterSQL(t *testing.T) {
	d := loadCPACK(t)
	sql := d.GenerateRegisterSQL()

	if !strings.Contains(sql, "INSERT INTO packml_register") {
		t.Error("missing INSERT")
	}
	if !strings.Contains(sql, "ON CONFLICT (packml_topic) WHERE active DO NOTHING;") {
		t.Error("register SQL must target the partial active-unique index (packml_topic_active_un, WHERE active)")
	}
	// The INSERT must carry the device_key column (ADR-0046 §2 declared identity).
	if !strings.Contains(sql, "device_key)") {
		t.Errorf("register INSERT must include the device_key column; got:\n%s", sql)
	}
	// A line (tp=3) → id_unit NULL; a member (tp=1) → id_unit = its id. Each row now
	// ends with the resolved device_key (dash form of the topic).
	if !strings.Contains(sql, "(3, 47, 'CPACK/SC/LINHAS/L5', true, NULL, 'CPACK-SC-LINHAS-L5')") {
		t.Errorf("expected L5 line row with NULL id_unit + device_key; got:\n%s", sql)
	}
	if !strings.Contains(sql, "(3, 53, 'CPACK/SC/LINHAS/L5/BREYER', true, 53, 'CPACK-SC-LINHAS-L5-BREYER')") {
		t.Errorf("expected L5/BREYER member row id_unit=53 + device_key; got:\n%s", sql)
	}
	// One VALUES row per equipment.
	rows := strings.Count(sql, "true,")
	if rows != len(d.Equipment) {
		t.Errorf("register rows=%d, want %d (one per equipment)", rows, len(d.Equipment))
	}
}

// TestGenerateEquipmentPositionSQL checks the flow-order backfill (artifact 2b):
// members ranked 1-based within their line in descriptor (infeed→outfeed) order,
// single cells → 1, lines/sectors skipped, and idempotent (tp_equipment guard).
func TestGenerateEquipmentPositionSQL(t *testing.T) {
	d := loadCPACK(t)
	sql := d.GenerateEquipmentPositionSQL()

	// L5 members BREYER..TEXA are positions 1..5 (descriptor list order = flow).
	wants := []string{
		"UPDATE equipments SET position = 1 WHERE id_equipment = 53 AND tp_equipment = 1;", // L5-BREYER infeed
		"UPDATE equipments SET position = 2 WHERE id_equipment = 54 AND tp_equipment = 1;", // L5-POLYTYPE
		"UPDATE equipments SET position = 3 WHERE id_equipment = 55 AND tp_equipment = 1;", // L5-PTH
		"UPDATE equipments SET position = 4 WHERE id_equipment = 56 AND tp_equipment = 1;", // L5-RMH
		"UPDATE equipments SET position = 5 WHERE id_equipment = 57 AND tp_equipment = 1;", // L5-TEXA outfeed
		"UPDATE equipments SET position = 4 WHERE id_equipment = 80 AND tp_equipment = 1;", // L10-TEXA (4-member line)
	}
	for _, w := range wants {
		if !strings.Contains(sql, w) {
			t.Errorf("missing expected UPDATE:\n  %s\ngot:\n%s", w, sql)
		}
	}

	// Single-machine cell member (CER400 member id 88) → position 1.
	if !strings.Contains(sql, "UPDATE equipments SET position = 1 WHERE id_equipment = 88 AND tp_equipment = 1;") {
		t.Errorf("single-cell CER400 member should be position 1; got:\n%s", sql)
	}

	// One UPDATE per tp=1 member; no line/sector rows.
	var members int
	for _, e := range d.Equipment {
		if e.TPEquipment == 1 {
			members++
		}
	}
	if got := strings.Count(sql, "UPDATE equipments SET position ="); got != members {
		t.Errorf("position UPDATEs=%d, want %d (one per tp=1 member)", got, members)
	}
}

// TestGenerateTeeSnippet asserts the tee flow (artifact 4) is valid Node-RED JSON
// carrying the descriptor's parameters — the ingest URL, the key-from-env
// discipline (secret never in the file), the tenant group scope, and the
// insecure-TLS choice. It is a STRUCTURAL equivalence to the hand-built
// docs/ingestion/cpack-tee-node.json (whose function body is heavily prose-
// commented and deliberately not byte-reproduced).
func TestGenerateTeeSnippet(t *testing.T) {
	d := loadCPACK(t)
	raw, err := d.GenerateTeeSnippet()
	if err != nil {
		t.Fatalf("GenerateTeeSnippet: %v", err)
	}
	var nodes []map[string]any
	if err := json.Unmarshal(raw, &nodes); err != nil {
		t.Fatalf("tee snippet is not valid JSON: %v", err)
	}
	byType := map[string]map[string]any{}
	for _, n := range nodes {
		byType[n["type"].(string)] = n
	}
	fn, ok := byType["function"]
	if !ok {
		t.Fatal("no function (tee) node")
	}
	body := fn["func"].(string)
	if !strings.Contains(body, `env.get("CPACK_INGEST_KEY")`) {
		t.Error("tee must read the ingest key from env, never hardcode it")
	}
	if !strings.Contains(body, "X-Ingest-Key") {
		t.Error("tee must set the X-Ingest-Key header")
	}
	if !strings.Contains(body, `gateway: "cpack-edge"`) {
		t.Errorf("tee must stamp the descriptor gateway; body:\n%s", body)
	}
	http, ok := byType["http request"]
	if !ok {
		t.Fatal("no http request node")
	}
	if http["url"] != d.Tee.IngestURL {
		t.Errorf("http url=%v want %q", http["url"], d.Tee.IngestURL)
	}
	tls, ok := byType["tls-config"]
	if !ok {
		t.Fatal("no tls-config node")
	}
	// descriptor tls_insecure:true ⇒ verifyservercert:false
	if tls["verifyservercert"] != false {
		t.Errorf("tls_insecure=true must yield verifyservercert=false, got %v", tls["verifyservercert"])
	}
}

// TestCutoverGate_RefusesInferred is the no-cutover-on-inferred rule (ADR-0045
// §2.4b): CPACK still carries inferred indices, so a --cutover generation MUST
// fail and name them, while the default (draft) generation succeeds.
func TestCutoverGate_RefusesInferred(t *testing.T) {
	d := loadCPACK(t)

	inferred := d.InferredMembers()
	if len(inferred) == 0 {
		t.Fatal("test premise broken: CPACK descriptor should carry inferred indices")
	}

	// Draft/observe generation succeeds.
	if _, err := d.Generate(GenerateOptions{Cutover: false}); err != nil {
		t.Fatalf("draft generation should succeed: %v", err)
	}

	// Cutover generation refuses and names the offenders.
	_, err := d.Generate(GenerateOptions{Cutover: true})
	if err == nil {
		t.Fatal("cutover generation must refuse while any index is inferred")
	}
	if !strings.Contains(err.Error(), "inferred") {
		t.Errorf("error should explain the inferred-index refusal: %v", err)
	}
	// Naming at least one offender lets CS Admin know exactly what to CAPTURE.
	if !strings.Contains(err.Error(), inferred[0]) {
		t.Errorf("refusal should name the inferred equipment %q; got %v", inferred[0], err)
	}
}

// TestCutoverGate_AllConfirmedPasses proves the gate OPENS once every index is
// confirmed — a synthetic all-confirmed clone of CPACK generates cutover config.
func TestCutoverGate_AllConfirmedPasses(t *testing.T) {
	d := loadCPACK(t)
	for i := range d.Equipment {
		if d.Equipment[i].CountIndex != nil {
			d.Equipment[i].CountIndex.Confidence = ConfidenceConfirmed
		}
	}
	if got := d.InferredMembers(); len(got) != 0 {
		t.Fatalf("expected zero inferred after confirming all, got %d", len(got))
	}
	if _, err := d.Generate(GenerateOptions{Cutover: true}); err != nil {
		t.Fatalf("cutover generation should pass once all confirmed: %v", err)
	}
}

// TestValidate_RejectsBadDescriptor exercises the up-front validation seam: a
// bad descriptor fails loudly at Load, not silently downstream in one artifact.
func TestValidate_RejectsBadDescriptor(t *testing.T) {
	base := loadCPACK(t)

	// Topic that does not start with the canonical prefix.
	d := *base
	d.Equipment = append([]Equipment(nil), base.Equipment...)
	d.Equipment[0].Topic = "OTHER/SC/LINHAS/L5"
	if err := d.Validate(); err == nil {
		t.Error("topic not under canonical.prefix must be rejected")
	}

	// Duplicate id_equipment.
	d = *base
	d.Equipment = append([]Equipment(nil), base.Equipment...)
	d.Equipment[1].IDEquipment = d.Equipment[0].IDEquipment
	if err := d.Validate(); err == nil {
		t.Error("duplicate id_equipment must be rejected")
	}

	// Bad confidence value.
	d = *base
	d.Equipment = append([]Equipment(nil), base.Equipment...)
	bad := *d.Equipment[1].CountIndex
	bad.Confidence = "maybe"
	d.Equipment[1].CountIndex = &bad
	if err := d.Validate(); err == nil {
		t.Error("bad count_index.confidence must be rejected")
	}

	// device_key with an illegal char (a "/" — it must be the flat identity).
	d = *base
	d.Equipment = append([]Equipment(nil), base.Equipment...)
	d.Equipment[0].DeviceKey = "CPACK/SC/BAD"
	if err := d.Validate(); err == nil {
		t.Error("device_key with '/' must be rejected (flat identity, not a topic)")
	}

	// Duplicate DECLARED device_key across two equipment.
	d = *base
	d.Equipment = append([]Equipment(nil), base.Equipment...)
	d.Equipment[0].DeviceKey = "DUPKEY"
	d.Equipment[1].DeviceKey = "DUPKEY"
	if err := d.Validate(); err == nil {
		t.Error("duplicate device_key across equipment must be rejected")
	}
}

// TestResolvedDeviceKey pins the declared-else-derived rule: a declared key is
// returned verbatim; an absent one is the dash-joined topic (the fixture form).
func TestResolvedDeviceKey(t *testing.T) {
	declared := Equipment{Topic: "CPACK/SC/LINHAS/L5/BREYER", DeviceKey: "CUSTOM-KEY"}
	if got := declared.ResolvedDeviceKey(); got != "CUSTOM-KEY" {
		t.Errorf("declared device_key: got %q, want CUSTOM-KEY", got)
	}
	derived := Equipment{Topic: "CPACK/SC/LINHAS/L5/BREYER"}
	if got := derived.ResolvedDeviceKey(); got != "CPACK-SC-LINHAS-L5-BREYER" {
		t.Errorf("derived device_key: got %q, want CPACK-SC-LINHAS-L5-BREYER", got)
	}
}
