// Tests for the client.yaml loader. The v1.1 descriptor schema
// (docs/adr/reference/designs/0021-tenant-descriptor-and-isolation-gate.md
// §1a) is parsed here as OPTIONAL typed sections; the two properties under
// test are:
//
//   - forward-compat: a skeleton config (cpack shape) and a fully-populated
//     v1.1 descriptor both Load() without error, and absent v1.1 sections
//     never trip a v1.1 validation.
//   - lint rules: each CI-lintable rule from §1a rejects its own violation.
//
// Configs are written to a temp file per case so the exercised path is the
// real one (os.ReadFile → yaml.Unmarshal → validate), not a struct built by
// hand.
package clientconfig

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeConfig drops a client.yaml into a temp dir and returns its path.
func writeConfig(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "client.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	return p
}

// skeletonCPack is the runtime-active cpack.yaml shape: skeleton fields only,
// no v1.1 sections. Must keep loading unchanged.
const skeletonCPack = `
tenant_id:    cpack
customer:     "C-Pack Solutions"
environment:  staging
equipments: []
`

// fullV11 populates every v1.1 section, mirroring the incoplast descriptor
// from the design doc §1a (secrets by reference, ERP dims, capabilities).
const fullV11 = `
schema_version: "1.1"
tenant_id:    incoplast
customer:     "Incoplast (São Ludgero)"
environment:  staging
equipments: []

plc:
  protocol: s7
  endpoints:
    - name: NovoFlex-015
      host_ref: secret://incoplast/plc/novoflex-015-host
      rack: 0
      slot: 2

equipment_mapping:
  - packml_topic: INCOPLAST/SL/EXTRUSAO/NovoFlex-015
    id_equipment: 41
    erp:
      recurso: EXT-015
      etapa:   EXTRUSAO

shifts:
  source: cloud_db

capabilities:
  operator:
    mode: edge
    language: pt-BR
  commands:
    enabled: true
    allowed: [po_setup, param_write]
  integrations:
    - type: database
      driver: oracle
      dsn_ref: secret://incoplast/erp/dsn
      reads:  [production_orders, scrap, users]
      writes: [downtime, production]
      dedup_key: id_external
  customizations:
    - custom-counter
    - reel-tracking
`

// TestLoadValid covers configs that must Load() without error, and asserts
// the parsed shape where it matters.
func TestLoadValid(t *testing.T) {
	t.Run("skeleton-only still loads (cpack shape)", func(t *testing.T) {
		cfg, err := Load(writeConfig(t, skeletonCPack))
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if cfg.TenantID != "cpack" {
			t.Errorf("TenantID = %q, want cpack", cfg.TenantID)
		}
		if got := cfg.Tenants(); len(got) != 1 || got[0] != "cpack" {
			t.Errorf("Tenants() = %v, want [cpack]", got)
		}
		// No v1.1 section should have been populated.
		if cfg.PLC != nil || cfg.Capabilities != nil || cfg.Shifts != nil {
			t.Errorf("skeleton config populated a v1.1 section: plc=%v caps=%v shifts=%v",
				cfg.PLC, cfg.Capabilities, cfg.Shifts)
		}
		if cfg.SchemaVersion != "" || len(cfg.EquipmentMapping) != 0 {
			t.Errorf("skeleton config populated v1.1 fields: version=%q mapping=%v",
				cfg.SchemaVersion, cfg.EquipmentMapping)
		}
	})

	t.Run("full v1.1 config loads with all sections populated", func(t *testing.T) {
		cfg, err := Load(writeConfig(t, fullV11))
		if err != nil {
			t.Fatalf("Load: %v", err)
		}
		if cfg.SchemaVersion != "1.1" {
			t.Errorf("SchemaVersion = %q, want 1.1", cfg.SchemaVersion)
		}
		// plc
		if cfg.PLC == nil || cfg.PLC.Protocol != "s7" || len(cfg.PLC.Endpoints) != 1 {
			t.Fatalf("plc not parsed: %+v", cfg.PLC)
		}
		ep := cfg.PLC.Endpoints[0]
		if ep.HostRef != "secret://incoplast/plc/novoflex-015-host" {
			t.Errorf("host_ref = %q", ep.HostRef)
		}
		if ep.Rack == nil || *ep.Rack != 0 || ep.Slot == nil || *ep.Slot != 2 {
			t.Errorf("rack/slot not parsed as pointers: rack=%v slot=%v", ep.Rack, ep.Slot)
		}
		// equipment_mapping + erp
		if len(cfg.EquipmentMapping) != 1 {
			t.Fatalf("equipment_mapping len = %d", len(cfg.EquipmentMapping))
		}
		if got := cfg.EquipmentMapping[0].ERP["recurso"]; got != "EXT-015" {
			t.Errorf("erp.recurso = %q, want EXT-015", got)
		}
		// shifts
		if cfg.Shifts == nil || cfg.Shifts.Source != "cloud_db" {
			t.Errorf("shifts = %+v", cfg.Shifts)
		}
		// capabilities
		if cfg.Capabilities == nil {
			t.Fatal("capabilities nil")
		}
		if cfg.Capabilities.Operator == nil || cfg.Capabilities.Operator.Mode != "edge" {
			t.Errorf("operator = %+v", cfg.Capabilities.Operator)
		}
		if cfg.Capabilities.Commands == nil || !cfg.Capabilities.Commands.Enabled ||
			len(cfg.Capabilities.Commands.Allowed) != 2 {
			t.Errorf("commands = %+v", cfg.Capabilities.Commands)
		}
		if len(cfg.Capabilities.Integrations) != 1 ||
			cfg.Capabilities.Integrations[0].DSNRef != "secret://incoplast/erp/dsn" {
			t.Errorf("integrations = %+v", cfg.Capabilities.Integrations)
		}
		if len(cfg.Capabilities.Customizations) != 2 {
			t.Errorf("customizations = %v", cfg.Capabilities.Customizations)
		}
	})
}

// TestValidationRejects covers each §1a lint rule firing on its violation.
// Every case is expected to FAIL Load() with an error containing wantErr.
func TestValidationRejects(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		wantErr string
	}{
		{
			name: "plc host_ref is a value, not a secret reference",
			body: `
tenant_id: incoplast
customer: "Incoplast"
environment: staging
plc:
  protocol: s7
  endpoints:
    - name: NovoFlex-015
      host_ref: 10.0.0.7
`,
			wantErr: "must be empty or a secret:// reference",
		},
		{
			name: "integration dsn_ref is a value, not a secret reference",
			body: `
tenant_id: incoplast
customer: "Incoplast"
environment: staging
capabilities:
  integrations:
    - type: database
      dsn_ref: "oracle://user:pass@10.0.0.9:1521/ORCL"
`,
			wantErr: "must be empty or a secret:// reference",
		},
		{
			name: "tenant_id does not match topic first segment",
			body: `
tenant_id: incoplast
customer: "Incoplast"
environment: staging
equipment_mapping:
  - packml_topic: CPACK/SL/EXTRUSAO/NovoFlex-015
    id_equipment: 41
`,
			wantErr: "must equal tenant_id",
		},
		{
			name: "operator.mode is neither cloud nor edge",
			body: `
tenant_id: incoplast
customer: "Incoplast"
environment: staging
capabilities:
  operator:
    mode: hybrid
`,
			wantErr: "must be cloud or edge",
		},
		{
			name: "commands.enabled without allowed list",
			body: `
tenant_id: incoplast
customer: "Incoplast"
environment: staging
capabilities:
  commands:
    enabled: true
    allowed: []
`,
			wantErr: "allowed is empty",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := Load(writeConfig(t, tc.body))
			if err == nil {
				t.Fatalf("Load succeeded, want error containing %q", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("error = %q, want it to contain %q", err.Error(), tc.wantErr)
			}
		})
	}
}

// TestAbsentSectionsSkipValidation asserts forward-compat: a config with the
// v1.1 sections ABSENT never trips a v1.1 rule, even the ones that would fire
// on a malformed present section. This is the parse-and-ignore contract that
// lets an old skeleton config keep booting after the loader grows.
func TestAbsentSectionsSkipValidation(t *testing.T) {
	// tenant_id here would MISMATCH the topic in fullV11, but with no
	// equipment_mapping present the rule must not fire.
	body := `
tenant_id: someothertenant
customer: "Skeleton After Grow"
environment: production
`
	cfg, err := Load(writeConfig(t, body))
	if err != nil {
		t.Fatalf("absent v1.1 sections must skip validation, got: %v", err)
	}
	if cfg.TenantID != "someothertenant" {
		t.Errorf("TenantID = %q", cfg.TenantID)
	}
}
