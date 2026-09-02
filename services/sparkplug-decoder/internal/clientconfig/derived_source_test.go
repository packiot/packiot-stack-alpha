package clientconfig

import (
	"os"
	"strings"
	"testing"
)

// TestTagSource_ValidAndInvalid exercises the reader-side mirror of the agent
// derive schema (ADR-0045 P2c): a tag with a `source:` (integral|sum) is DERIVED
// — it carries no physical address, so the db/offset/type checks are skipped and
// the source shape is validated instead.
func TestTagSource_ValidAndInvalid(t *testing.T) {
	// A derived S7 tag (integral) — no db/offset/type needed.
	valid := `
schema_version: "1.1"
tenant_id: acme
customer: ACME
environment: staging
canonical_prefix: ACME/SP
plc:
  endpoints:
    - name: line-plc
      host_ref: secret://acme/host
      rack: 0
      slot: 1
s7_tag_map:
  - endpoint: line-plc
    packml_topic: ACME/SP/L5/FLEXO
    id_equipment: 5001
    tags:
      - metric: "/Admin/ProdConsumedCount/61/Unit"
        source:
          integral:
            source: "/Status/CurMachSpeed"
            conversion: 0.0167
      - metric: "/Status/MachSpeed"
        db: 1
        offset: 8
        type: real
`
	if _, err := loadFromString(t, valid); err != nil {
		t.Fatalf("valid derived tag rejected: %v", err)
	}

	cases := []struct {
		name    string
		source  string // the YAML block under the derived tag's `source:`
		wantErr string
	}{
		{
			name:    "both integral and sum",
			source:  "          integral:\n            source: \"/Status/Sp\"\n          sum:\n            addends: [\"/a\", \"/b\"]",
			wantErr: "exactly one of {integral, sum}",
		},
		{
			name:    "sum with one addend",
			source:  "          sum:\n            addends: [\"/only\"]",
			wantErr: "at least two suffixes",
		},
		{
			name:    "integral without source",
			source:  "          integral:\n            conversion: 1",
			wantErr: "integral.source is required",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			yaml := `
schema_version: "1.1"
tenant_id: acme
customer: ACME
environment: staging
canonical_prefix: ACME/SP
plc:
  endpoints:
    - name: line-plc
      host_ref: secret://acme/host
s7_tag_map:
  - endpoint: line-plc
    packml_topic: ACME/SP/L5/FLEXO
    id_equipment: 5001
    tags:
      - metric: "/Admin/ProdConsumedCount/61/Unit"
        source:
` + tc.source + "\n"
			_, err := loadFromString(t, yaml)
			if err == nil {
				t.Fatalf("want error containing %q, got nil", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("error %q does not contain %q", err.Error(), tc.wantErr)
			}
		})
	}
}

// loadFromString writes the YAML to a temp file and runs the REAL loader.
func loadFromString(t *testing.T, yaml string) (*Config, error) {
	t.Helper()
	dir := t.TempDir()
	path := dir + "/client.yaml"
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	return Load(path)
}
