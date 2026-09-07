package main

import (
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// external_jsonb_reader_test.go — the §3c key-ORDER axis. Proves nodePgJSONText
// reserializes a Postgres jsonb text value byte-identically to node-postgres
// (JSON.parse → Express JSON.stringify). Every `want` below was computed with a
// LIVE node v22 reference (`JSON.stringify(JSON.parse(in))`) on the ACTUAL prod
// jsonb `::text` sampled SELECT-only from production_orders.custom_field and
// equipment_validation_shift.txt_validation_notes, plus the number/key-order edge
// cases that separate this from a naive json.Compact or a pgx map round-trip.

func TestNodePgJSONText(t *testing.T) {
	cases := []struct {
		name string
		in   string // Postgres jsonb ::text (with its whitespace)
		want string // exact node-pg output (JSON.parse→JSON.stringify)
	}{
		{
			// REAL production_orders.custom_field row.
			"custom_field_real",
			`{"STATUS": 1, "id_order": 357226, "priority": 10, "cd_client": 34407, "scrap_factor": 44.32910965352669, "PRODUCTION_STEP": 62, "VERSION_PRODUCT": "9"}`,
			`{"STATUS":1,"id_order":357226,"priority":10,"cd_client":34407,"scrap_factor":44.32910965352669,"PRODUCTION_STEP":62,"VERSION_PRODUCT":"9"}`,
		},
		{
			// REAL txt_validation_notes row: nested object, key order note<user<
			// approved<ip_adress<ts_confirm preserved; embedded \n kept as \n.
			"txt_validation_notes_real",
			`{"LastConfirm": {"note": "BC should be 21344\nPP should be 19872", "user": "Hmoujib", "approved": true, "ip_adress": "", "ts_confirm": "2026-07-17T04:18:38.010Z"}}`,
			`{"LastConfirm":{"note":"BC should be 21344\nPP should be 19872","user":"Hmoujib","approved":true,"ip_adress":"","ts_confirm":"2026-07-17T04:18:38.010Z"}}`,
		},
		{
			// KEY ORDER: jsonb stores length-then-byte (b,z,aa,ccc). node-pg keeps
			// it; pgx's map decode would SORT alphabetically (aa,b,ccc,z) — the bug.
			"key_order_length_then_byte",
			`{"b": 2, "z": 4, "aa": 1, "ccc": 3}`,
			`{"b":2,"z":4,"aa":1,"ccc":3}`,
		},
		{
			// NUMBERS via IEEE-754: 1.50→1.5, 100.0→100, >2^53 loses precision
			// EXACTLY as JS, 1000 stays 1000. json.Compact would keep "1.50" here.
			"number_normalization",
			`{"a": 1.50, "b": 100.0, "c": 9007199254740993, "d": 1000}`,
			`{"a":1.5,"b":100,"c":9007199254740992,"d":1000}`,
		},
		{"array", `[1, 2, {"k": "v"}]`, `[1,2,{"k":"v"}]`},
		{"scalar_null", `null`, `null`},
		{"scalar_string", `"hello"`, `"hello"`},
		{"scalar_int", `42`, `42`},
		{"scalar_bool", `true`, `true`},
		{"empty_object", `{}`, `{}`},
		// No HTML escaping — Express JSON.stringify leaves < > & as-is.
		{"no_html_escape", `{"x": "<A&B>"}`, `{"x":"<A&B>"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := nodePgJSONText([]byte(c.in))
			if err != nil {
				t.Fatalf("nodePgJSONText: %v", err)
			}
			if string(got) != c.want {
				t.Errorf("nodePgJSONText mismatch\n in:   %s\n got:  %s\n want: %s", c.in, got, c.want)
			}
		})
	}
}

// TestIsNodePgJSONOID pins jsonb (3802) + json (114) as the JSON-container OIDs,
// and confirms numeric/int8/text are NOT treated as JSON containers.
func TestIsNodePgJSONOID(t *testing.T) {
	for _, oid := range []uint32{pgtype.JSONBOID, pgtype.JSONOID} {
		if !isNodePgJSONOID(oid) {
			t.Errorf("OID %d must be a node-pg JSON container", oid)
		}
	}
	for _, oid := range []uint32{pgtype.NumericOID, pgtype.Int8OID, pgtype.TextOID, oidMoney} {
		if isNodePgJSONOID(oid) {
			t.Errorf("OID %d must NOT be a JSON container", oid)
		}
	}
}

// TestExternalTextForcedFormats confirms the reader forces BOTH the numeric set
// (numeric/int8/money) AND the JSON set (jsonb/json) onto the text wire, and
// nothing else.
func TestExternalTextForcedFormats(t *testing.T) {
	want := []uint32{pgtype.NumericOID, pgtype.Int8OID, oidMoney, pgtype.JSONBOID, pgtype.JSONOID}
	for _, oid := range want {
		if f, ok := externalTextForcedFormats[oid]; !ok || f != pgx.TextFormatCode {
			t.Errorf("OID %d must be forced to text (ok=%v fmt=%d)", oid, ok, f)
		}
	}
	if len(externalTextForcedFormats) != len(want) {
		t.Errorf("externalTextForcedFormats has %d entries, want %d", len(externalTextForcedFormats), len(want))
	}
}

// TestApplyNodePgJSONForm covers the per-row substitution: a jsonb column becomes
// a rawJSON (reserialized), a NULL becomes rawJSON(nil), unflagged cols untouched.
func TestApplyNodePgJSONForm(t *testing.T) {
	vals := []any{
		map[string]any{"z": 1, "a": 2}, // whatever pgx decoded — overwritten
		"keepme",
		[]byte("ignored-null"), // this column is NULL on the wire (raw nil)
	}
	raw := [][]byte{
		[]byte(`{"z": 1, "a": 2}`),
		[]byte("keepme"),
		nil, // NULL jsonb
	}
	jsonPass := []bool{true, false, true}
	if err := applyNodePgJSONForm(vals, raw, jsonPass); err != nil {
		t.Fatalf("applyNodePgJSONForm: %v", err)
	}
	rj, ok := vals[0].(rawJSON)
	if !ok || string(rj) != `{"z":1,"a":2}` {
		t.Errorf("jsonb col: got %#v, want rawJSON {\"z\":1,\"a\":2} (order preserved, compact)", vals[0])
	}
	if vals[1] != "keepme" {
		t.Errorf("unflagged col mutated: %#v", vals[1])
	}
	if rj2, ok := vals[2].(rawJSON); !ok || rj2 != nil {
		t.Errorf("NULL jsonb col: got %#v, want rawJSON(nil) (→ JSON null)", vals[2])
	}
}

// TestRawJSONMarshalsVerbatim proves externalRows.MarshalJSON emits a rawJSON as
// an OBJECT (not a quoted string) and a nil rawJSON as null — the whole point of
// the jsonb axis vs the numeric axis (which quotes).
func TestRawJSONMarshalsVerbatim(t *testing.T) {
	er := externalRows{
		cols: []string{"id_order", "custom_field", "txt_notes"},
		rows: [][]any{{
			5501,
			rawJSON([]byte(`{"STATUS":1,"scrap_factor":44.32910965352669}`)),
			rawJSON(nil), // NULL jsonb
		}},
	}
	got, err := er.MarshalJSON()
	if err != nil {
		t.Fatalf("MarshalJSON: %v", err)
	}
	want := `[{"id_order":5501,"custom_field":{"STATUS":1,"scrap_factor":44.32910965352669},"txt_notes":null}]`
	if string(got) != want {
		t.Errorf("rawJSON marshal:\n got:  %s\n want: %s", got, want)
	}
}
