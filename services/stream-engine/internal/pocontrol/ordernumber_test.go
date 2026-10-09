package pocontrol

import (
	"encoding/json"
	"testing"
)

func TestOrderNumberUnmarshal(t *testing.T) {
	for _, c := range []struct {
		name, raw, want string
	}{
		{"alphanumeric string", `"ORD-1"`, "ORD-1"},
		{"numeric string", `"218300"`, "218300"},
		{"leading zero kept", `"08396260"`, "08396260"},
		{"dotted string kept", `"834.058"`, "834.058"},
		{"integer number", `123`, "123"},
		{"decimal number literal kept", `834.058`, "834.058"},
		{"trailing zero decimal kept", `834.050`, "834.050"},
		{"big number not truncated", `99999999999`, "99999999999"},
		{"negative number", `-5`, "-5"},
		{"whitespace trimmed", `"  ORD 7  "`, "ORD 7"},
		{"inner whitespace kept", `"A  B"`, "A  B"},
		{"empty string = absent", `""`, ""},
		{"blank string = absent", `"   "`, ""},
		{"null = absent", `null`, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			var o OrderNumber
			if err := json.Unmarshal([]byte(c.raw), &o); err != nil {
				t.Fatalf("unmarshal %s: %v", c.raw, err)
			}
			if o.String() != c.want {
				t.Fatalf("got %q, want %q", o, c.want)
			}
			if o.IsZero() != (c.want == "") {
				t.Fatalf("IsZero()=%v for %q", o.IsZero(), o)
			}
		})
	}
}

func TestOrderNumberRejectsNonScalar(t *testing.T) {
	for _, raw := range []string{`true`, `{}`, `[1]`, `"unterminated`} {
		var o OrderNumber
		if err := json.Unmarshal([]byte(raw), &o); err == nil {
			t.Errorf("%s: expected an error, got %q", raw, o)
		}
	}
}

func TestOrderNumberAbsentField(t *testing.T) {
	var p struct {
		N OrderNumber `json:"id_order"`
	}
	if err := json.Unmarshal([]byte(`{}`), &p); err != nil || !p.N.IsZero() {
		t.Fatalf("absent field: err=%v n=%q", err, p.N)
	}
}

func TestOrderNumberMarshalIsString(t *testing.T) {
	b, err := json.Marshal(struct {
		N OrderNumber `json:"n"`
	}{N: "08396260"})
	if err != nil || string(b) != `{"n":"08396260"}` {
		t.Fatalf("marshal: %s %v", b, err)
	}
}
