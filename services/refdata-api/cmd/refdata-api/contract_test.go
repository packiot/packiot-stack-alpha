package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestContractParses is the fail-loud guard: extraction must classify EVERY
// dataset and route into at least one backing object, with a well-formed shape.
// A new dataset whose SQL the parser can't handle fails here (and --dump-contract),
// rather than silently escaping the prod-drift gate.
func TestContractParses(t *testing.T) {
	objs, err := extractContract()
	if err != nil {
		t.Fatalf("extractContract: %v", err)
	}

	// Every dataset and every route must contribute ≥1 object.
	refs := map[string]bool{}
	for _, o := range objs {
		refs[o.Ref] = true
		switch o.Kind {
		case "function":
			if o.ArgC <= 0 {
				t.Errorf("%s: function %s has argc %d (want ≥1)", o.Ref, o.Name, o.ArgC)
			}
			if len(o.Columns) != 0 {
				t.Errorf("%s: function %s must not carry columns", o.Ref, o.Name)
			}
		case "relation":
			// columns may be empty (existence-only) — that is valid.
		default:
			t.Errorf("%s: object %s has unknown kind %q", o.Ref, o.Name, o.Kind)
		}
		if !isIdent(o.Name) {
			t.Errorf("%s: backing object name %q is not a bare identifier", o.Ref, o.Name)
		}
	}
	for name := range datasets {
		if !refs[name] {
			t.Errorf("dataset %q produced no contract object — parser gap", name)
		}
	}
	for _, ep := range endpoints {
		if !refs[ep.path] {
			t.Errorf("route %q produced no contract object — parser gap", ep.path)
		}
	}
}

// TestContractGolden locks the extracted contract against a committed golden so
// any datasets.go / endpoints change that shifts a backing object, arity, or
// projected column is a visible, reviewable diff. Refresh with:
//
//	UPDATE_GOLDEN=1 go test ./cmd/refdata-api/ -run TestContractGolden
//
// When you refresh it, the CI drift gate (scripts/refdata-contract-drift-check.sh)
// should be re-run against prod before the change ships.
func TestContractGolden(t *testing.T) {
	goldenPath := filepath.Join("testdata", "contract.golden.json")

	var got bytes.Buffer
	if err := dumpContract(&got); err != nil {
		t.Fatalf("dumpContract: %v", err)
	}

	if os.Getenv("UPDATE_GOLDEN") == "1" {
		if err := os.WriteFile(goldenPath, got.Bytes(), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		t.Logf("golden updated: %s", goldenPath)
		return
	}

	want, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read golden (run with UPDATE_GOLDEN=1 to create): %v", err)
	}

	// Compare semantically (normalize both through json) so trailing-newline /
	// formatting noise never fails the gate.
	var gotV, wantV any
	if err := json.Unmarshal(got.Bytes(), &gotV); err != nil {
		t.Fatalf("unmarshal got: %v", err)
	}
	if err := json.Unmarshal(want, &wantV); err != nil {
		t.Fatalf("unmarshal golden: %v", err)
	}
	gotN, _ := json.Marshal(gotV)
	wantN, _ := json.Marshal(wantV)
	if !bytes.Equal(gotN, wantN) {
		t.Errorf("contract drifted from golden.\nRegenerate with: UPDATE_GOLDEN=1 go test ./cmd/refdata-api/ -run TestContractGolden\nand re-run scripts/refdata-contract-drift-check.sh against prod.\n got:  %s\n want: %s", gotN, wantN)
	}
}

// TestParseSQLShapes exercises the parser's classification directly on the
// contract's load-bearing shapes, independent of the live registry, so a
// regression in the parser is caught with a precise message.
func TestParseSQLShapes(t *testing.T) {
	cases := []struct {
		name string
		sql  string
		want []contractObject
	}{
		{
			name: "function simple",
			sql:  `SELECT * FROM h_piot_home_uns($1)`,
			want: []contractObject{{Kind: "function", Name: "h_piot_home_uns", ArgC: 1}},
		},
		{
			name: "function with literal NULL arg counted",
			sql:  `SELECT * FROM h_piot_get_events_timeline_full_with_filter_3($1,$2,$3,$4,$5,NULL,$6,$7)`,
			want: []contractObject{{Kind: "function", Name: "h_piot_get_events_timeline_full_with_filter_3", ArgC: 8}},
		},
		{
			name: "perEquipment: function + guard relation",
			sql: `SELECT f.* FROM h_piot_overview_i_get_job_info($2) f WHERE EXISTS
				(SELECT 1 FROM equipments e WHERE e.id_equipment = $2 AND e.id_enterprise = $1)`,
			want: []contractObject{
				{Kind: "function", Name: "h_piot_overview_i_get_job_info", ArgC: 1},
				{Kind: "relation", Name: "equipments"},
			},
		},
		{
			name: "relation SELECT * → existence-only",
			sql:  `SELECT * FROM production_targets WHERE id_enterprise = $1`,
			want: []contractObject{{Kind: "relation", Name: "production_targets"}},
		},
		{
			name: "relation explicit columns",
			sql: `SELECT id_equipment, nm_equipment, downtime_reasons FROM equipments
				WHERE id_enterprise = $1 AND id_equipment = $2`,
			want: []contractObject{{Kind: "relation", Name: "equipments", Columns: []string{"id_equipment", "nm_equipment", "downtime_reasons"}}},
		},
		{
			name: "two-relation JOIN with qualified columns",
			sql: `SELECT r.ts_value, r.target, e.nm_equipment
				FROM equipment_runtime_1month r JOIN equipments e USING (id_equipment)
				WHERE e.id_enterprise = $1 AND e.id_equipment = $2`,
			want: []contractObject{
				{Kind: "relation", Name: "equipment_runtime_1month", Columns: []string{"ts_value", "target"}},
				{Kind: "relation", Name: "equipments", Columns: []string{"nm_equipment"}},
			},
		},
		{
			name: "liveUNS alias.* → existence-only + guard",
			sql: `SELECT t.* FROM uns_equipment_current_shift t JOIN equipments e USING (id_equipment)
				WHERE e.id_enterprise = $1 AND (cardinality($2::int[]) = 0 OR t.id_equipment = ANY($2::int[]))`,
			want: []contractObject{
				{Kind: "relation", Name: "uns_equipment_current_shift"},
				{Kind: "relation", Name: "equipments"},
			},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := parseSQL(c.sql)
			if err != nil {
				t.Fatalf("parseSQL: %v", err)
			}
			gj, _ := json.Marshal(got)
			wj, _ := json.Marshal(c.want)
			if string(gj) != string(wj) {
				t.Errorf("parseSQL mismatch\n got:  %s\n want: %s", gj, wj)
			}
		})
	}
}

// TestParseSQLRejectsUnparseable proves the fail-loud contract: an expression
// in a projection (not a plain column) must ERROR, not silently drop from the
// contract.
func TestParseSQLRejectsUnparseable(t *testing.T) {
	bad := []string{
		`SELECT count(*) FROM enterprises WHERE id_enterprise = $1`,
		`SELECT a.col FROM enterprises e WHERE id_enterprise = $1`, // unknown alias a
		`SELECT id_enterprise`, // no FROM
	}
	for _, sql := range bad {
		if _, err := parseSQL(sql); err == nil {
			t.Errorf("parseSQL accepted unparseable SQL: %q", sql)
		}
	}
}
