package agentcfg

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const validYAML = `
sparkplug:
  group_id: CPACK
  edge_node_id: sparkplug-agent-cpack
  packml_topic: CPACK/SC/LINHAS/L5/BREYER
  internal_broker: tcp://mosquitto:1883
  uplink_broker: ssl://edge.example:8883
  uplink_tls_cert_ref: secret://packiot/staging/cpack-cert
  uplink_tls_key_ref: secret://packiot/staging/cpack-key
raw_tag_map:
  - metric_suffix: /Status/MachSpeed
    type: double
  - metric_suffix: /Admin/ProdProcessedCount/1/Unit
    type: long
  - metric_suffix: /Status/PoNumber
    name: CPACK/EXPLICIT/OVERRIDE/PoNumber
    type: string
`

func writeCfg(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "agent.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoad_Valid(t *testing.T) {
	cfg, err := Load(writeCfg(t, validYAML))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if cfg.Sparkplug.RawTopic != DefaultRawTopic {
		t.Errorf("raw_topic default: got %q, want %q", cfg.Sparkplug.RawTopic, DefaultRawTopic)
	}
	// FullName: prefix + suffix, unless an explicit name overrides.
	tm := cfg.TagMap()
	if got := tm["/Status/MachSpeed"].FullName(cfg.Sparkplug.PackMLTopic); got != "CPACK/SC/LINHAS/L5/BREYER/Status/MachSpeed" {
		t.Errorf("FullName prefix+suffix: got %q", got)
	}
	if got := tm["/Status/PoNumber"].FullName(cfg.Sparkplug.PackMLTopic); got != "CPACK/EXPLICIT/OVERRIDE/PoNumber" {
		t.Errorf("FullName explicit override: got %q", got)
	}
}

func TestLoad_RejectsInlineSecret(t *testing.T) {
	bad := strings.Replace(validYAML,
		"uplink_tls_cert_ref: secret://packiot/staging/cpack-cert",
		"uplink_tls_cert_ref: -----BEGIN CERTIFICATE-----", 1)
	_, err := Load(writeCfg(t, bad))
	if err == nil || !strings.Contains(err.Error(), "uplink_tls_cert_ref") {
		t.Fatalf("inline secret must be rejected, got err=%v", err)
	}
}

func TestLoad_RejectsBadType(t *testing.T) {
	bad := strings.Replace(validYAML, "type: double", "type: int128", 1)
	if _, err := Load(writeCfg(t, bad)); err == nil {
		t.Fatal("invalid type token must be rejected")
	}
}

func TestLoad_RequiresIdentity(t *testing.T) {
	if _, err := Load(writeCfg(t, strings.Replace(validYAML, "group_id: CPACK", "group_id: \"\"", 1))); err == nil {
		t.Fatal("missing group_id must be rejected")
	}
}
